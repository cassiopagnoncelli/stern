module Stern
  class PaySettlement < BaseOperation
    attr_accessor :settlement_id, :merchant_id, :amount, :fee

    def initialize(settlement_id: nil, merchant_id: nil, amount: nil, fee: nil)
      @settlement_id = settlement_id
      @merchant_id = merchant_id
      @amount = amount
      @fee = fee
    end

    def perform
      raise ParameterMissingError unless settlement_id.present? && settlement_id.is_a?(Numeric)
      raise ParameterMissingError unless merchant_id.present? && merchant_id.is_a?(Numeric)
      raise ParameterMissingError unless amount.present? && amount.is_a?(Numeric)
      raise ParameterMissingError unless fee.present? && fee.is_a?(Numeric)
      raise AmountShouldNotBeZeroError if amount.zero?

      credits = ::Stern.balance(merchant_id, :merchant_credit)
      charged_credits = [fee, credits].min
      charged_fees = fee - charged_credits

      credit_tx_id = apply_credits(charged_credits, merchant_id)
      Tx.add_settlement_fee(settlement_id, merchant_id, charged_fees)
      Tx.add_settlement(settlement_id, merchant_id, amount, credit_tx_id)
    end

    def undo
      raise ParameterMissingError unless settlement_id.present? && settlement_id.is_a?(Numeric)

      credit_tx_id = Tx.find_by!(code: TXS[:add_settlement], uid: settlement_id).credit_tx_id

      Tx.remove_credit(credit_tx_id) if credit_tx_id.present?
      Tx.remove_settlement_fee(settlement_id)
      Tx.remove_settlement(settlement_id)
    end
  end
end
