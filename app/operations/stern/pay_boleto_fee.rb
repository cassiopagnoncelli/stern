module Stern
  class PayBoletoFee < BaseOperation
    attr_accessor :payment_id, :merchant_id, :fee

    def initialize(payment_id: nil, merchant_id: nil, fee: nil)
      @payment_id = payment_id
      @merchant_id = merchant_id
      @fee = fee
    end

    def perform
      raise ParameterMissingError unless payment_id.present? && payment_id.is_a?(Numeric)
      raise ParameterMissingError unless merchant_id.present? && merchant_id.is_a?(Numeric)
      raise ParameterMissingError unless fee.present? && fee.is_a?(Numeric)
      raise AmountShouldNotBeZeroError unless fee.abs.positive?

      credits = ::Stern.balance(merchant_id, :merchant_credit)
      charged_credits = [fee, credits].min
      charged_fees = fee - charged_credits

      credit_tx_id = apply_credits(charged_credits, merchant_id)
      Tx.add_boleto_fee(payment_id, merchant_id, charged_fees, credit_tx_id)
    end

    def undo
      raise ParameterMissingError unless payment_id.present? && payment_id.is_a?(Numeric)

      credit_tx_id = Tx.find_by!(code: TXS[:add_boleto_fee], uid: payment_id).credit_tx_id
      Tx.remove_credit(credit_tx_id) if credit_tx_id.present?
      Tx.remove_boleto_fee(payment_id)
    end
  end
end
