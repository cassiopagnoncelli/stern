module Stern
  class BaseOperation
    def call(direction: :do, transaction: true)
      case direction
      when :do, :redo, :forward, :forwards, :perform
        fun = lambda { perform }
        transaction ? ApplicationRecord.transaction { fun.call } : fun.call
      when :undo, :backward, :backwards
        fun = lambda { undo }
        transaction ? ApplicationRecord.transaction { fun.call } : fun.call
      else
        raise OperationDirectionNotProvidedError, "provide `direction` with :do or :undo"
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
      raise CreditTxIdSeqInvalidError unless remaining_tries.positive?

      seq = ::Stern::Tx.generate_tx_credit_id

      already_present = Tx.find_by(code: Tx.codes[:add_credit], uid: seq).present?
      already_present ? new_credit_tx_id(remaining_tries - 1) : seq
    end

    def apply_credits(charged_credits, merchant_id, ts0)
      return nil unless charged_credits.present? && charged_credits.abs.positive?

      credit_tx_id = new_credit_tx_id
      Tx.add_credit(credit_tx_id, merchant_id, -charged_credits, ts0)
      credit_tx_id
    end
  end
end
