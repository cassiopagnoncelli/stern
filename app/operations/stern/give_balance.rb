module Stern
  class GiveBalance < BaseOperation
    attr_accessor :uid, :merchant_id, :amount

    def initialize(uid: nil, merchant_id: nil, amount: nil)
      @uid = uid
      @merchant_id = merchant_id
      @amount = amount
    end

    def perform
      raise ParameterMissingError unless uid.present? && uid.is_a?(Numeric)
      raise ParameterMissingError unless merchant_id.present? && merchant_id.is_a?(Numeric)
      raise ParameterMissingError unless amount.present? && amount.is_a?(Numeric)
      raise AmountShouldNotBeZeroError if amount.zero?

      Tx.add_balance(uid, merchant_id, amount)
    end

    def undo
      raise ParameterMissingError unless uid.present? && uid.is_a?(Numeric)

      tx = Tx.find_by!(code: TXS[:add_balance], uid:)
      Tx.remove_balance(tx.id)
    end
  end
end
