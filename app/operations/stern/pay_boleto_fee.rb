module Stern
  class PayBoletoFee < BaseOperation
    attr_accessor :payment_id, :merchant_id, :fee, :timestamp

    def initialize(payment_id: nil, merchant_id: nil, fee: nil, timestamp: DateTime.current)
      @payment_id = payment_id
      @merchant_id = merchant_id
      @fee = fee
      @timestamp = timestamp
    end

    def perform
      raise ParameterMissingError unless payment_id.present? && payment_id.is_a?(Numeric)
      raise ParameterMissingError unless merchant_id.present? && merchant_id.is_a?(Numeric)
      raise ParameterMissingError unless fee.present? && fee.is_a?(Numeric)
      raise ParameterMissingError unless timestamp.present? && timestamp.is_a?(DateTime)
      raise AmountShouldNotBeZeroError unless fee.abs.positive?

      credits = ::Stern.balance(merchant_id, :merchant_credit)
      charged_credits = [fee, credits].min
      charged_fees = fee - charged_credits

      credit_tx_id = apply_credits(charged_credits, merchant_id, timestamp)
      Tx.add_boleto_fee(payment_id, merchant_id, charged_fees, timestamp, credit_tx_id, cascade: false)
    end

    def undo
      raise ParameterMissingError unless payment_id.present? && payment_id.is_a?(Numeric)

      credit_tx_id = Tx.find_by!(code: Tx.codes[:add_boleto_fee], uid: payment_id).credit_tx_id
      Tx.remove_credit(credit_tx_id) if credit_tx_id.present?
      Tx.remove_boleto_fee(payment_id)
    end
  end
end
