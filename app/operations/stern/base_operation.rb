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
  #     name: 'ChargePix',
  #     params: { charge_id: 1, merchant_id: 1101, customer_id: 2, amount: 9900, currency: 'usd' },
  #     after_time: 10.seconds.from_now
  #   )
  # > sop.save!
  #
  class BaseOperation
    attr_accessor :operation

    class << self
      def inputs(*names)
        @inputs ||= []
        return @inputs if names.empty?

        @inputs.concat(names)
        attr_accessor(*names)
      end
    end

    def initialize(**kwargs)
      extra = kwargs.keys - self.class.inputs
      raise ArgumentError, "unknown inputs for #{self.class.name}: #{extra}" if extra.any?

      self.class.inputs.each { |n| public_send("#{n}=", kwargs[n]) }
      normalize_shared_inputs
      normalize_inputs
    end

    # Hook for subclasses to coerce/transform assigned inputs. Runs after
    # `normalize_shared_inputs`, so subclasses don't need to call `super`.
    def normalize_inputs; end

    # Declares the `(book, gid, currency)` tuples this operation reads from or writes
    # to. `BaseOperation#call` takes a per-tuple Postgres advisory lock on each before
    # `perform` runs, so concurrent ops on the same tuples serialize while ops on
    # disjoint tuples run in parallel.
    #
    # Subclasses override with something like:
    #
    #   def target_tuples
    #     tuples_for_pair(:pp_charge_pix, merchant_id, currency)
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

    # Runs the operation. Returns the Operation id (either a new one or, when `idem_key`
    # matches an existing operation with identical params, the existing one).
    #
    # @param transaction [Boolean] wrap log + perform in a transaction with table locks.
    #   Defaults to true; set false when the caller is already managing a transaction.
    # @param idem_key [String, nil] idempotency key. If present and an Operation with this
    #   key already exists with identical name/params, returns its id without re-running.
    def call(transaction: true, idem_key: nil)
      existing = find_existing_operation(idem_key)
      return existing.id if existing

      begin
        if transaction
          ApplicationRecord.transaction do
            acquire_advisory_locks(target_tuples)
            record_and_perform(idem_key)
          end
        else
          record_and_perform(idem_key)
        end
      rescue ActiveRecord::RecordNotUnique => e
        # Lost the race against another concurrent caller with the same
        # idem_key. Our transaction has rolled back; the other caller's
        # Operation row is now committed. Return its id so the race is
        # benign from this caller's perspective. Any RecordNotUnique not
        # tied to idem_key propagates unchanged.
        winner = idem_key && Operation.find_by(idem_key: idem_key)
        raise e if winner.nil?
        return winner.id
      end

      operation.id
    end

    def perform
      raise NotImplementedError
    end

    def perform_undo
      raise NotImplementedError
    end

    def new_gid
      raise NotImplementedError
    end

    def display
      params_str = operation_params.map { |k, v| "#{k}=#{v}" }.join(" ")
      format(
        "{%<operation_uid>3d} %<operation_name>s: %<params_str>s",
        operation_uid:,
        operation_name:,
        params_str:,
      )
    end

    private

    # Coerces shared inputs common across operations (e.g. `currency` from its
    # string name to its integer code). Runs before the subclass `normalize_inputs`
    # hook so subclasses see already-canonical values. `Stern.cur(_, result: :index)`
    # is idempotent for integer inputs, so this is safe whether the caller passed
    # a name or a code.
    def normalize_shared_inputs
      self.currency = cur(currency, result: :index) if self.class.inputs.include?(:currency) && currency
    end

    # Creates the Operation audit record and dispatches to the subclass's `perform`.
    # Mutates `self.operation` so the subclass can access it via attr_accessor.
    def record_and_perform(idem_key)
      log_operation(idem_key)
      perform(operation.id)
    end

    def log_operation(idem_key)
      self.operation = Operation.new(name: operation_name, params: operation_params, idem_key:)
      operation.save!
      operation.id
    end

    # Helper for the common double-entry pattern: returns the two `(book, gid, currency)`
    # tuples `EntryPair.add_<pair_name>(...)` will write to.
    def tuples_for_pair(pair_name, gid, currency)
      pair = ::Stern.chart.entry_pair(pair_name)
      raise ArgumentError, "unknown entry pair #{pair_name.inspect}" unless pair

      [ [ pair.book_add, gid, currency ], [ pair.book_sub, gid, currency ] ]
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
    def find_existing_operation(idem_key)
      return nil if idem_key.nil?

      op = Operation.find_by(idem_key:)
      return nil if op.nil?
      return op if op.name == operation_name && op.params == operation_params

      raise "Operation with idem_key #{idem_key} already exists with different parameters"
    end
  end
end
