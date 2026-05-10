module Stern
  # Operations are top-level API commands to handle entry pairs and therefore entries.
  # Use cases are all thought in terms of operations. A direct consequence is models
  # should never be used or manipulated directly, instead operations should be used.
  #
  # All operations have to be backwards compatible.
  #
  # To schedule an operation, you may want to use
  #
  # > sop = ScheduledOperation.build(
  #     name: 'ChargePayment',
  #     params: { charge_id: 1, merchant_id: 1101, customer_id: 2, amount: 9900, currency: 'usd' },
  #     after_time: 10.seconds.from_now
  #   )
  # > sop.save!
  #
  # ## Per-cause gid partitioning
  #
  # `EntryPair.add_<pair>(uid, gid, amount, …)` writes both legs of the pair at
  # the single `gid` the caller passes. That `gid` is **the cause of the entry**,
  # not the owner of the book. So a single `merchant_available` book can carry
  # entries keyed by the merchant (deposits, credit applications), by a payment
  # (fee charges), by a withdrawal (locks), etc. — each subset captures one
  # cause's contribution to the merchant's balance.
  #
  # Two consequences worth knowing:
  #
  #   1. **Per-gid balance reads are partial.** `BalanceQuery(gid: merchant_id,
  #      book_id: :merchant_available)` returns only the slice written at
  #      `gid = merchant_id` — credits, deposits, transfers — not fee charges
  #      keyed by `payment_id` or withdrawal locks keyed by `withdrawal_id`. The
  #      stakeholder's *true* available balance is the sum across all gids on
  #      that book. Treat per-gid reads as cause-scoped, not owner-scoped.
  #
  #   2. **Lock keys diverge from entry keys, by design.** `tuples_for_pair`
  #      returns the lock granularity ("the natural sharding entity for the
  #      operation"), which doesn't have to match the gid the entries are
  #      written at. `ChargePaymentFee` locks `(merchant_available, merchant_id)`
  #      to serialize against other merchant-level ops, but writes the fee
  #      entries at `gid = payment_id` so per-payment fee balances are
  #      retrievable. `target_tuples` decides who *blocks*; `add_<pair>(…, gid,
  #      …)` decides where the entries *land*.
  #
  # Where multiple ops touch the same book at the same logical entity, the
  # advisory locks serialize them. Where they touch the same book at different
  # logical entities (e.g. two fee charges on different payments to the same
  # merchant), they don't — by design — so unrelated work runs in parallel.
  class BaseOperation
    include ActiveModel::Validations

    extend RetryPolicy
    include InputsDsl
    include StakeholderPairing
    include AdvisoryLocking
    include Idempotency

    # Public aliases of the policy constants. Defined on `RetryPolicy` (where
    # the methods that read them live) and re-exposed here so callers can
    # reach them as `Stern::BaseOperation::DEFAULT_RETRY_POLICY` without
    # threading the module name. Constants point to the same frozen objects.
    DEFAULT_RETRY_POLICY = RetryPolicy::DEFAULT_RETRY_POLICY
    SUPPORTED_BACKOFF_STRATEGIES = RetryPolicy::SUPPORTED_BACKOFF_STRATEGIES
    STAKEHOLDER_TYPES = StakeholderPairing::STAKEHOLDER_TYPES
    FUNDER_TYPES = StakeholderPairing::FUNDER_TYPES

    attr_accessor :operation

    def cur(name_or_index, result: :both)
      ::Stern.cur(name_or_index, result:)
    end

    # Runs the operation. Returns the Operation id (either a new one or, when `idem_key`
    # matches an existing operation with identical params, the existing one).
    #
    # **Fail-fast.** `call` does not retry. Any exception raised from validation,
    # advisory-lock acquisition, `runtime_check`, or `perform` propagates to the
    # caller, and the surrounding transaction rolls back — the `Operation` audit
    # row is destroyed with it. Retries are the responsibility of
    # `Stern::ScheduledOperation` / `ScheduledOperationService`, which use the
    # class-level `retry_policy` to schedule re-execution under a stable
    # `idem_key`. Direct `call` users that want retries should schedule instead.
    #
    # @param transaction [Boolean] wrap log + perform in a transaction with table locks.
    #   Defaults to true; set false when the caller is already managing a transaction.
    # @param idem_key [String, nil] idempotency key. If present and an Operation with this
    #   key already exists with identical name/params, returns its id without re-running.
    def call(transaction: true, idem_key: nil)
      raise ArgumentError, errors.full_messages.to_sentence if invalid?

      normalize_validated_inputs

      existing = find_existing_operation(idem_key)
      return existing.id if existing

      attempted_at = Time.current
      attempt_params = json_normalized_params

      begin
        if transaction
          ApplicationRecord.transaction do
            acquire_advisory_locks(target_tuples)
            record_and_perform(idem_key)
          end
        else
          record_and_perform(idem_key)
        end

        record_attempt!(:success, attempted_at, attempt_params, idem_key, operation_id: operation.id)
        operation.id
      rescue ActiveRecord::RecordNotUnique => e
        # Race-loser path: we lost an INSERT race on stern_operations.idem_key.
        # Two narrowing requirements before we can treat this as a benign replay:
        #
        #   1. The unique-violation must be on the idem_key index — not on any
        #      other unique constraint (e.g. an entries-table index hit during
        #      `perform`). Otherwise we'd mask real bugs as idempotent successes.
        #   2. The winner's name+params must match ours. Otherwise this is the
        #      same hazard `find_existing_operation` raises on, just observed
        #      one statement later through a transaction rollback. Routing
        #      through `find_existing_operation` keeps both detection paths in
        #      sync — same comparison, same raise.
        unless idem_key && Operation.idem_key_collision?(e)
          record_attempt!(:failed, attempted_at, attempt_params, idem_key, error: e)
          raise e
        end

        existing = find_existing_operation(idem_key)
        if existing.nil? # winner deleted between rollback and reread; treat as fault
          record_attempt!(:failed, attempted_at, attempt_params, idem_key, error: e)
          raise e
        end

        record_attempt!(:success, attempted_at, attempt_params, idem_key, operation_id: existing.id)
        existing.id
      rescue StandardError => e
        record_attempt!(:failed, attempted_at, attempt_params, idem_key, error: e)
        raise
      end
    end

    def perform
      raise NotImplementedError
    end

    # Hook for subclasses to verify state-dependent preconditions that cannot be
    # expressed as input validations (e.g. balance checks against a book that
    # was just locked by `acquire_advisory_locks`). Runs after the audit row is
    # written and before `perform`, so the read sees the same snapshot the
    # writes will use. Add violations via `errors.add(...)`; `BaseOperation`
    # will raise `ArgumentError` with `errors.full_messages.to_sentence` if any
    # are present, matching the shape of input-validation failures.
    #
    # Subclasses may also assign to inputs (e.g. fill in a defaulted amount
    # from a balance read) since this runs under the operation's locks.
    def runtime_check; end

    private

    # Creates the Operation audit record and dispatches to the subclass's `perform`.
    # Mutates `self.operation` so the subclass can access it via attr_accessor.
    # Between the audit row and `perform`, runs `runtime_check` so subclasses
    # can verify state-dependent preconditions under the advisory locks; any
    # `errors` accumulated there raise `ArgumentError` with the same message
    # shape as input-validation failures.
    def record_and_perform(idem_key)
      log_operation(idem_key)
      runtime_check
      raise ArgumentError, errors.full_messages.to_sentence if errors.any?

      perform(operation.id)
    end

    def log_operation(idem_key)
      self.operation = Operation.new(name: operation_name, params: operation_params, idem_key:)
      operation.save!
      operation.id
    end

    # Friendly pre-check for ops that move funds out of a `(book, gid, currency)`
    # slice: reads the per-gid balance under the operation's advisory lock and
    # raises `Stern::InsufficientFunds` when `amount` would overdraw it. The
    # DB-level `non_negative` constraint on guarded books would translate the
    # same condition into `BalanceNonNegativeViolation`; we raise the parent
    # `InsufficientFunds` here so callers can rescue both layers uniformly.
    #
    # `op_label` and `balance_label` shape the message as
    # `"#{op_label} amount #{amount} exceeds #{balance_label} #{current}"`,
    # so existing callers (and their specs) can keep the exact phrasing they
    # had before extraction.
    def require_sufficient_balance!(book_id:, gid:, currency:, amount:, op_label:, balance_label:)
      current = BalanceQuery.new(gid:, book_id:, currency:, timestamp: Time.current).call
      return if amount <= current

      raise ::Stern::InsufficientFunds,
        "#{op_label} amount #{amount} exceeds #{balance_label} #{current}"
    end

    def operation_name
      self.class.name.demodulize
    end

    # Writes an `OperationAttempt` row recording this call. Runs outside the
    # operation's transaction (the rescue path observes a rolled-back state),
    # so the attempt persists even when `perform` raises and the `Operation`
    # row is destroyed. Defensive: failures here are logged but never re-raised
    # — masking the caller's actual error would be worse than losing one audit
    # entry.
    def record_attempt!(status, attempted_at, params, idem_key, operation_id: nil, error: nil)
      OperationAttempt.create!(
        name: operation_name,
        params: params,
        idem_key: idem_key,
        operation_id: operation_id,
        status: status,
        attempted_at: attempted_at,
        error_class: error&.class&.name,
        error_message: error&.message,
        error_backtrace: error&.backtrace&.first(OperationAttempt::BACKTRACE_LINES)&.join("\n"),
      )
    rescue StandardError => attempt_error
      Rails.logger.error(
        "[Stern::BaseOperation] failed to record OperationAttempt " \
        "(#{operation_name}, status=#{status}): #{attempt_error.class}: #{attempt_error.message}"
      )
      nil
    end
  end
end
