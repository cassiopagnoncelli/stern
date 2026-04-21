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

    def cur(name_or_index, result: :both)
      ::Stern.cur(name_or_index, result:)
    end

    def call(transaction: true, idem_key: nil)
      base_operation = self

      op_id = find_existing_operation(transaction, idem_key)
      return op_id if op_id.present?

      operation_id = nil

      fun = lambda {
        operation_id = log_operation(base_operation, idem_key)
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
      
      operation_id
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

    def log_operation(base_operation = self, idem_key = nil)
      base_operation.operation = Operation.new(
        name: operation_name,
        params: operation_params,
        idem_key:,
      )
      base_operation.operation.save!
      base_operation.operation.id
    end

    private

    def lock_tables
      ApplicationRecord.lock_table(table: EntryPair.table_name)
      ApplicationRecord.lock_table(table: Entry.table_name)
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

    def find_existing_operation(transaction, idem_key)
      return nil if idem_key.nil?

      op = Operation.find_by(idem_key:)
      return nil if op.nil?
      
      return op.id if
        op.name == operation_name && 
        op.params == operation_params
        
      raise "Operation with idem_key #{idem_key} already exists with different parameters"
    end
  end
end
