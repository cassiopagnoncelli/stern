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

    # Public aliases of the policy constants. Defined on `RetryPolicy` (where
    # the methods that read them live) and re-exposed here so callers can
    # reach them as `Stern::BaseOperation::DEFAULT_RETRY_POLICY` without
    # threading the module name. Constants point to the same frozen objects.
    DEFAULT_RETRY_POLICY = RetryPolicy::DEFAULT_RETRY_POLICY
    SUPPORTED_BACKOFF_STRATEGIES = RetryPolicy::SUPPORTED_BACKOFF_STRATEGIES

    attr_accessor :operation

    class << self
      def inputs(*names)
        @inputs ||= []
        return @inputs if names.empty?

        @inputs.concat(names)
        attr_accessor(*names)
      end

      # Declares that exactly one of the given attributes must be present. Adds an
      # error on `:base` when the count is not 1, so validation messages flow through
      # the standard `errors.full_messages` path instead of bare `ArgumentError`s
      # raised from `perform`.
      def validates_exactly_one_of(*attrs)
        validate do
          present = attrs.count { |a| public_send(a).present? }
          next if present == 1

          errors.add(:base, "exactly one of #{attrs.join(', ')} must be set (got #{present})")
        end
      end

      # Generates `target_tuples`, `perform`, and (optionally) `runtime_check`
      # for the dominant single-pair shape: an op picks a stakeholder/funder via
      # `stakeholder_for` / `funder_for`, formats one entry-pair name from the
      # type, locks the pair's two `(book, gid, currency)` tuples, then writes
      # `EntryPair.add_<pair>(uid, gid, amount, currency, operation_id:)`.
      #
      # `pair_template` is a printf-style string with `%{type}` interpolated
      # from the helper's returned type symbol, e.g. `"unlock_%{type}_balance"`,
      # `"%{type}_credit"`, `"reverse_withdrawal_%{type}"`.
      #
      # `using:` picks the polymorphism helper. `:stakeholder_for` (default)
      # scans `merchant`/`customer`/`partner`; `:funder_for` scans
      # `merchant`/`partner` only — for ops where `customer_id` is a recipient,
      # not a stakeholder candidate (see `ReverseRefund`).
      #
      # `sub_gid:` / `add_gid:` choose the gid passed to `tuples_for_pair` for
      # each side, and (by default) the matching arg to `EntryPair.add_<pair>`.
      # Pass `:resolved` (default) for the id returned by the configured
      # helper, or any input symbol (e.g. `:payment_id`, `:refund_id`).
      #
      # `entry_uid:` / `entry_gid:` override the args to `EntryPair.add_<pair>`
      # (entry uid / cause-of-entry, and the gid both legs land at) for the
      # rare cases where the lock-side gids and the entry-side gids diverge —
      # `ReverseRefund` writes the entry at `(uid: refund_id, gid: funder_id)`
      # while locking on `customer_id`/`funder_id`; `CancelRefund` writes at
      # `(uid: stakeholder_id, gid: refund_id)` while locking on
      # `refund_id`/`stakeholder_id`. Default to `sub_gid` / `add_gid`.
      #
      # `requires_balance:` declares a friendly pre-check via
      # `require_sufficient_balance!`. Keys:
      #   * `book:`        — Symbol (literal book) or String (interpolated with `%{type}`)
      #   * `label:`       — `balance_label:` for the error message
      #   * `gid:`         — slot for the balance read; defaults to `sub_gid`
      #   * `bypass_when:` — method/attr that, when truthy, skips the check
      #
      # `op_label` for the error message is always
      # `name.demodulize.underscore`. Subclasses may override any generated
      # method to extend the behavior.
      #
      # `requires_credit_application:` (default false) extends the macro to the
      # ChargeFee shape: locks an additional `apply_<type>_credit` pair on the
      # stakeholder, and prepends a call to `apply_available_credit` inside the
      # generated `perform` so any standing credit drains into `*_available`
      # before the fee is debited. Used by the four `Charge*Fee` ops.
      #
      # `pair_template` may also reference any input attribute via `%{name}`
      # (e.g. `"charge_%{payment_method}_fee_%{type}"`); all declared inputs
      # are interpolated at call time alongside the resolved `:type`.
      def performs_stakeholder_pair(pair_template,
                                    using: :stakeholder_for,
                                    sub_gid: :resolved,
                                    add_gid: :resolved,
                                    entry_uid: nil,
                                    entry_gid: nil,
                                    requires_balance: nil,
                                    requires_credit_application: false)
        helper       = using
        uid_slot     = entry_uid || sub_gid
        gid_slot     = entry_gid || add_gid
        balance_cfg  = requires_balance
        needs_credit = requires_credit_application

        define_method(:target_tuples) do
          rid, type = public_send(helper)
          pair = pair_template_for(pair_template, type).to_sym
          tuples = tuples_for_pair(pair,
            gid_for_slot(sub_gid, rid),
            gid_for_slot(add_gid, rid),
            currency)
          if needs_credit
            tuples += tuples_for_pair("apply_#{type}_credit".to_sym, rid, rid, currency)
          end
          tuples
        end

        define_method(:perform) do |operation_id|
          rid, type = public_send(helper)
          apply_available_credit(rid, type, operation_id) if needs_credit
          pair = "add_#{pair_template_for(pair_template, type)}".to_sym
          EntryPair.public_send(pair,
            gid_for_slot(uid_slot, rid),
            gid_for_slot(gid_slot, rid),
            amount, currency, operation_id:)
        end

        return unless balance_cfg

        bal_book    = balance_cfg.fetch(:book)
        bal_label   = balance_cfg.fetch(:label)
        bal_gid     = balance_cfg.fetch(:gid, sub_gid)
        bypass_when = balance_cfg[:bypass_when]

        define_method(:runtime_check) do
          next if bypass_when && public_send(bypass_when)

          rid, type = public_send(helper)
          book = bal_book.is_a?(Symbol) ? bal_book : (bal_book % { type: type }).to_sym
          require_sufficient_balance!(
            book_id:       book,
            gid:           gid_for_slot(bal_gid, rid),
            currency:,
            amount:,
            op_label:      self.class.name.demodulize.underscore,
            balance_label: bal_label,
          )
        end
      end
    end

    validate :currency_must_be_known

    def initialize(**kwargs)
      extra = kwargs.keys - self.class.inputs
      raise ArgumentError, "unknown inputs for #{self.class.name}: #{extra}" if extra.any?

      self.class.inputs.each { |n| public_send("#{n}=", kwargs[n]) }
      normalize_inputs
    end

    # Hook for subclasses to coerce/transform assigned inputs. Runs at the end
    # of `initialize`, so subclasses don't need to call `super`. Currency
    # normalization is deferred to `call` so unknown currencies surface as
    # validation errors rather than raising from the constructor.
    def normalize_inputs; end

    # Declares the `(book, gid, currency)` tuples this operation reads from or writes
    # to. `BaseOperation#call` takes a per-tuple Postgres advisory lock on each before
    # `perform` runs, so concurrent ops on the same tuples serialize while ops on
    # disjoint tuples run in parallel.
    #
    # Subclasses override with something like:
    #
    #   def target_tuples
    #     tuples_for_pair(:pp_charge_pix, merchant_id, merchant_id, currency)
    #   end
    #
    # Book references can be Symbols/Strings (resolved via the chart) or integer codes.
    # Return [] to opt out of locking (the operation has no data dependency).
    def target_tuples
      []
    end

    def cur(name_or_index, result: :both)
      ::Stern.cur(name_or_index, result:)
    end

    # Returns `[id, type]` for the first present `<prefix><type>_id` input,
    # scanning `:merchant`, `:customer`, `:partner` in that order. Returns
    # `[nil, nil]` when none is set.
    #
    # `prefix` lets ops with multiple stakeholder slots (e.g. `TransferBalance`'s
    # `from_*` / `to_*`) reuse the same scan:
    #
    #   stakeholder_for           # → [merchant_id, :merchant] etc.
    #   stakeholder_for("from_")  # → [from_merchant_id, :merchant] etc.
    #
    # Subclasses pair this with `validates_exactly_one_of` on the same fields
    # so exactly one branch is reachable after validation.
    STAKEHOLDER_TYPES = %i[merchant customer partner].freeze
    FUNDER_TYPES = %i[merchant partner].freeze

    def stakeholder_for(prefix = "")
      STAKEHOLDER_TYPES.each do |type|
        attr = :"#{prefix}#{type}_id"
        next unless self.class.inputs.include?(attr)

        id = public_send(attr)
        return [ id, type ] if id.present?
      end

      [ nil, nil ]
    end

    # Returns `[id, type]` for the first present `<prefix><type>_id` input
    # restricted to funder roles (`:merchant`, `:partner`) — distinct from
    # `stakeholder_for`, which would return `customer_id` first when an op
    # carries it as a recipient rather than as a stakeholder candidate
    # (e.g. `ReverseRefund`).
    def funder_for(prefix = "")
      FUNDER_TYPES.each do |type|
        attr = :"#{prefix}#{type}_id"
        next unless self.class.inputs.include?(attr)

        id = public_send(attr)
        return [ id, type ] if id.present?
      end

      [ nil, nil ]
    end

    # Resolves a gid slot used by `performs_stakeholder_pair`. The sentinel
    # `:resolved` returns the id from the configured polymorphism helper
    # (`stakeholder_for` / `funder_for`); any other Symbol is treated as an
    # input name and read via `public_send`.
    def gid_for_slot(slot, resolved_id)
      slot == :resolved ? resolved_id : public_send(slot)
    end

    # Interpolates `pair_template` with the resolved stakeholder `type` plus
    # every declared input attribute, so templates may reference inputs
    # directly (e.g. `"charge_%{payment_method}_fee_%{type}"`). Extra keys are
    # ignored by Ruby's `%` operator; missing keys raise KeyError.
    def pair_template_for(pair_template, type)
      args = { type: type }
      self.class.inputs.each { |inp| args[inp] = public_send(inp) }
      pair_template % args
    end

    # Drains standing `<type>_credit` into `<type>_available` up to `amount`
    # before a fee is debited. Used by ops declared with
    # `performs_stakeholder_pair ..., requires_credit_application: true`.
    # No-op for non-positive amounts (fee reversals leave the credit alone).
    def apply_available_credit(stakeholder_id, stakeholder_type, operation_id)
      return unless amount.positive?

      credit_balance = ::Stern.balance(stakeholder_id, "#{stakeholder_type}_credit".to_sym, currency)
      credit_to_apply = [ credit_balance, amount ].min
      return unless credit_to_apply.positive?

      EntryPair.public_send(
        "add_apply_#{stakeholder_type}_credit".to_sym,
        stakeholder_id, stakeholder_id, credit_to_apply, currency, operation_id:,
      )
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

    # Validates that `currency` (when declared as an input) refers to a known
    # currency. Runs through `Stern.cur` and translates `UnknownCurrencyError`
    # into a regular validation error so callers see `errors.full_messages`
    # rather than a raw raise from the constructor. Blank values fall through
    # to the subclass's `presence` validation.
    def currency_must_be_known
      return unless self.class.inputs.include?(:currency)
      return if currency.blank?

      ::Stern.cur(currency, result: :index)
    rescue ::Stern::UnknownCurrencyError
      errors.add(:currency, "is not a recognized currency")
    end

    # Canonicalizes validated inputs (e.g. currency name → integer code). Runs
    # in `call` after `invalid?` passes, so unknown values cannot reach this
    # point. `Stern.cur(_, result: :index)` is idempotent for integer inputs.
    def normalize_validated_inputs
      self.currency = ::Stern.cur(currency, result: :index) if self.class.inputs.include?(:currency) && currency
    end

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

    # Helper for the common double-entry pattern: returns the two `(book, gid, currency)`
    # tuples to lock for an `EntryPair.add_<pair_name>(...)` write. Each gid is the
    # natural sharding entity for its side's book — independent of the other side
    # and independent of the single `gid` the caller passes to `EntryPair.add_<pair_name>`.
    #
    # Examples:
    #
    #   * ChargePayment (`charge_<method>`: book_sub=payment_<method>, book_add=payment)
    #     — sub side is sharded by `charge_id` (one charge per row in `payment_<method>`),
    #     add side by `payment_id` — pass `(charge_id, payment_id)`.
    #
    #   * ChargePaymentFee (`charge_<method>_fee_merchant`: book_sub=merchant_available,
    #     book_add=payment_fee_<method>) — sub side by the stakeholder, add side by the
    #     payment — pass `(merchant_id, payment_id)`.
    #
    #   * TransferBalance (`merchant_available`) — both sides sharded by the same
    #     `merchant_id` — pass it twice.
    def tuples_for_pair(pair_name, book_sub_gid, book_add_gid, currency)
      pair = ::Stern.chart.entry_pair(pair_name)
      raise ArgumentError, "unknown entry pair #{pair_name.inspect}" unless pair

      [ [ pair.book_sub, book_sub_gid, currency ], [ pair.book_add, book_add_gid, currency ] ]
    end

    # Takes a transaction-scoped Postgres advisory lock on each `(book_id, gid, currency)`
    # tuple. Sorts by `[book_id, gid, currency]` to eliminate deadlock risk: any two
    # concurrent operations requesting overlapping tuples will acquire them in the same
    # order regardless of how their `target_tuples` is written. `pg_advisory_xact_lock`
    # is reentrant and releases at commit/rollback.
    def acquire_advisory_locks(tuples)
      return if tuples.empty?

      resolved = tuples.map do |book_ref, gid, currency|
        book_id = book_ref.is_a?(Integer) ? book_ref : ::Stern.chart.book_code(book_ref)
        raise ArgumentError, "unknown book #{book_ref.inspect}" unless book_id

        [ book_id, gid, currency ]
      end

      resolved.sort.uniq.each do |book_id, gid, currency|
        ApplicationRecord.advisory_lock(book_id:, gid:, currency:)
      end
    end

    def operation_name
      self.class.name.demodulize
    end

    def operation_params
      self.class.inputs.to_h { |n| [ n.to_s, public_send(n) ] }
    end

    # Looks up an Operation by idem_key. Returns the matching Operation if params also
    # match, nil if no Operation with that key exists, and raises if one exists with
    # different params (attempted replay with changed inputs).
    #
    # Comparison goes through `json_normalized_params` so live Ruby values (Symbols,
    # Times, BigDecimals, …) compare equal to the JSON-roundtripped shape that
    # `Operation.params` returns from its `json` column. Without this, replaying an
    # op whose inputs include any non-Integer/String/Bool would falsely diverge from
    # its stored row.
    def find_existing_operation(idem_key)
      return nil if idem_key.nil?

      op = Operation.find_by(idem_key:)
      return nil if op.nil?
      return op if op.name == operation_name && op.params == json_normalized_params

      raise ::Stern::IdempotencyConflict.new(
        idem_key: idem_key,
        existing: op,
        attempted_name: operation_name,
        attempted_params: operation_params,
      )
    end

    # `operation_params` projected through JSON's type system, so the result has the
    # same shape as `Operation.params` after a round-trip through the `json` column.
    def json_normalized_params
      JSON.parse(operation_params.to_json)
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
