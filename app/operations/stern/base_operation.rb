module Stern
  # Operations are top-level API commands to handle txs and therefore entries.
  # Use cases are all thought in terms of operations. A direct consequence is models
  # should never be used or manipulated directly, instead operations should be used.
  #
  # All operations have to be backwards compatible.
  class BaseOperation
    def call(direction: :do, transaction: true)
      case direction
      when :do, :redo, :forward, :forwards, :perform
        fun = lambda { perform }
        transaction ? ApplicationRecord.transaction { lock_tables; fun.call } : fun.call
      when :undo, :backward, :backwards
        fun = lambda { undo }
        transaction ? ApplicationRecord.transaction { lock_tables; fun.call } : fun.call
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

    def undo
      raise NotImplementedError
    end

    def new_gid
      raise NotImplementedError
    end

    def new_credit_tx_id(remaining_tries = 10)
      raise RuntimeError, "remaining tries exhausted while generating credit_tx_id" unless remaining_tries.positive?

      seq = ::Stern::Tx.generate_tx_credit_id

      already_present = Tx.find_by(code: Tx.codes[:add_credit], uid: seq).present?
      already_present ? new_credit_tx_id(remaining_tries - 1) : seq
    end

    def apply_credits(charged_credits, merchant_id)
      return nil unless charged_credits.present? && charged_credits.abs.positive?

      credit_tx_id = new_credit_tx_id
      Tx.add_credit(credit_tx_id, merchant_id, -charged_credits)
      credit_tx_id
    end

    private

    def lock_tables
      ApplicationRecord.lock_table(table: Tx.table_name)
      ApplicationRecord.lock_table(table: Entry.table_name)
    end
  end
end
