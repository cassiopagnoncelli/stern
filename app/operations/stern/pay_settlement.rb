module Stern
  class PaySettlement < BaseOperation
    attr_accessor :settlement_id, :merchant_id, :amount, :fee, :timestamp

    def initialize(settlement_id: nil, merchant_id: nil, amount: nil, fee: nil, timestamp: DateTime.current)
      @settlement_id = settlement_id
      @merchant_id = merchant_id
      @amount = amount
      @timestamp = timestamp
    end

    def perform
      raise ParameterMissingError unless settlement_id.present? && settlement_id.is_a?(Numeric)
      raise ParameterMissingError unless merchant_id.present? && merchant_id.is_a?(Numeric)
      raise ParameterMissingError unless amount.present? && amount.is_a?(Numeric)
      raise ParameterMissingError unless timestamp.present? && timestamp.is_a?(DateTime)
      raise AmountShouldNotBeZeroError if amount.zero?

      credits = ::Stern.balance(merchant_id, :merchant_credit)
      charged_credits = [fee, credits].min
      charged_fees = fee - charged_credits

      ts0 = timestamp
      ts1 = timestamp + STERN_TIMESTAMP_DELTA
      ts2 = timestamp + 2 * STERN_TIMESTAMP_DELTA

      credit_tx_id = apply_credits(charged_credits, merchant_id, ts0)
      Tx.add_settlement_fee(settlement_id, merchant_id, charged_fees, ts1, nil)
      Tx.add_settlement(settlement_id, merchant_id, amount, ts2, credit_tx_id)
    end

    def undo
      raise ParameterMissingError unless settlement_id.present? && settlement_id.is_a?(Numeric)

      credit_tx_id = Tx.find_by!(code: Tx.codes[:add_settlement], uid: settlement_id).credit_tx_id

      Tx.remove_credit(credit_tx_id) if credit_tx_id.present?
      Tx.remove_settlement_fee(settlement_id)
      Tx.remove_settlement(settlement_id)
    end
  end
end
