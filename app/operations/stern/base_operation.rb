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
  #     name: 'PayPix',
  #     params: { payment_id: 123, merchant_id: 1101, amount: 9900, fee: 65 },
  #     after_time: 10.seconds.from_now
  #   )
  # > sop.save!
  #
  class BaseOperation
    attr_accessor :operation

    def call(direction: :do, transaction: true)
      raise NotImplementedError unless operation_uid.is_a?(Integer)

      base_operation = self
      case direction
      when :do, :redo, :forward, :forwards, :perform
        fun = lambda {
          log_operation(:do, base_operation)
          perform(base_operation.operation.id)
        }
        if transaction
          ApplicationRecord.transaction do
            lock_tables
            fun.call
          end
        else
          fun.call
        end
      when :undo, :backward, :backwards
        fun = lambda {
          log_operation(:undo, base_operation)
          perform_undo
        }
        if transaction
          ApplicationRecord.transaction do
            lock_tables
            fun.call
          end
        else
          fun.call
        end
      else
        raise ArgumentError, "provide `direction` with :do or :undo"
      end
    end

    def call_undo
      call(direction: :undo)
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

    def new_credit_entry_pair_id(remaining_tries = 10)
      unless remaining_tries.positive?
        raise "remaining tries exhausted while generating credit_entry_pair_id"
      end

      seq = ::Stern::EntryPair.generate_entry_pair_credit_id

      already_present = EntryPair.find_by(code: EntryPair.codes[:add_credit], uid: seq).present?
      already_present ? new_credit_entry_pair_id(remaining_tries - 1) : seq
    end

    def apply_credits(charged_credits, merchant_id)
      return nil unless charged_credits.present? && charged_credits.abs.positive?

      credit_entry_pair_id = new_credit_entry_pair_id
      EntryPair.add_credit(credit_entry_pair_id, merchant_id, -charged_credits, operation_id:)
      credit_entry_pair_id
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

    def log_operation(direction, base_operation = self)
      raise ArgumentError unless direction.in?([:do, :undo])

      base_operation.operation = Operation.new(
        name: operation_name,
        direction:,
        params: operation_params,
      )
      base_operation.operation.save!
      base_operation.operation
    end

    private

    def lock_tables
      ApplicationRecord.lock_table(table: EntryPair.table_name)
      ApplicationRecord.lock_table(table: Entry.table_name)
    end

    def operation_uid
      self.class::UID
    end

    def operation_name
      self.class.to_s.gsub("Stern::", "")
    end

    def operation_params
      attr_accessor_hash = {}

      instance_variables.each do |ivar|
        attr_name = ivar.to_s.gsub("@", "")
        attr_value = instance_variable_get(ivar)
        attr_accessor_hash[attr_name] = attr_value
      end

      attr_accessor_hash
    end
  end
end
