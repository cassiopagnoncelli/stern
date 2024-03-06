module Stern
  # Operations are top-level API commands to handle txs and therefore entries.
  # Use cases are all thought in terms of operations. A direct consequence is models
  # should never be used or manipulated directly, instead operations should be used.
  #
  # All operations have to be backwards compatible.
  class BaseOperation
    def call(direction: :do, transaction: true)
      raise NotImplementedError unless get_uid.is_a?(Integer)

      case direction
      when :do, :redo, :forward, :forwards, :perform
        fun = lambda {
          operation = Operation.build(name: get_name, direction: :do, params: get_params)
          operation.save!
          perform(operation.id)
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
          Operation.build(name: get_name, direction: :undo, params: get_params).save!
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

    def new_credit_tx_id(remaining_tries = 10)
      unless remaining_tries.positive?
        raise "remaining tries exhausted while generating credit_tx_id"
      end

      seq = ::Stern::Tx.generate_tx_credit_id

      already_present = Tx.find_by(code: Tx.codes[:add_credit], uid: seq).present?
      already_present ? new_credit_tx_id(remaining_tries - 1) : seq
    end

    def apply_credits(charged_credits, merchant_id)
      return nil unless charged_credits.present? && charged_credits.abs.positive?

      credit_tx_id = new_credit_tx_id
      Tx.add_credit(credit_tx_id, merchant_id, -charged_credits, operation_id:)
      credit_tx_id
    end

    private

    def lock_tables
      ApplicationRecord.lock_table(table: Tx.table_name)
      ApplicationRecord.lock_table(table: Entry.table_name)
    end

    def get_uid
      self.class::UID
    end

    def get_name
      self.class.to_s.gsub("Stern::", "")
    end

    def get_params
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
