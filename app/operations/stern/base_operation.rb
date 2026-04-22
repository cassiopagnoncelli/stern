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
      normalize_inputs
    end

    # Hook for subclasses to coerce/transform assigned inputs.
    def normalize_inputs; end

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

      if transaction
        ApplicationRecord.transaction do
          lock_tables
          record_and_perform(idem_key)
        end
      else
        record_and_perform(idem_key)
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

    def lock_tables
      ApplicationRecord.lock_table(table: EntryPair.table_name)
      ApplicationRecord.lock_table(table: Entry.table_name)
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
