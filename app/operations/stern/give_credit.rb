module Stern
  class GiveCredit < BaseOperation
    attr_accessor :uid, :merchant_id, :amount, :timestamp

    def initialize(uid: nil, merchant_id: nil, amount: nil, timestamp: DateTime.current)
      @uid = uid
      @merchant_id = merchant_id
      @amount = amount
      @timestamp = timestamp
    end

    def perform
      raise ParameterMissingError unless uid.present? && uid.is_a?(Numeric)
      raise ParameterMissingError unless merchant_id.present? && merchant_id.is_a?(Numeric)
      raise ParameterMissingError unless amount.present? && amount.is_a?(Numeric)
      raise ParameterMissingError unless timestamp.present? && timestamp.is_a?(DateTime)
      raise AmountShouldNotBeZeroError if amount.zero?

      Tx.add_credit(uid, merchant_id, amount, timestamp, nil)
    end

    def undo
      raise ParameterMissingError unless uid.present? && uid.is_a?(Numeric)

      tx = Tx.find_by!(code: Tx.codes[:add_credit], uid: uid)
      Tx.remove_credit(tx.id)
    end
  end
end
