module Stern
  class PayBoleto < BaseOperation
    attr_accessor :payment_id, :merchant_id, :amount, :fee, :timestamp

    def initialize(payment_id: nil, merchant_id: nil, amount: nil, fee: nil, timestamp: DateTime.current)
      @payment_id = payment_id
      @merchant_id = merchant_id
      @amount = amount
      @fee = fee
      @timestamp = timestamp
    end

    def perform
      raise ParameterMissingError unless payment_id.present? && payment_id.is_a?(Numeric)
      raise ParameterMissingError unless merchant_id.present? && merchant_id.is_a?(Numeric)
      raise ParameterMissingError unless amount.present? && amount.is_a?(Numeric)
      raise ParameterMissingError unless fee.present? && fee.is_a?(Numeric)
      raise ParameterMissingError unless timestamp.present? && timestamp.is_a?(DateTime)
      raise AmountShouldNotBeZeroError if amount.zero?

      credits = ::Stern.balance(merchant_id, :merchant_credit)
      charged_credits = [fee, credits].min
      charged_fees = fee - charged_credits

      ts0 = timestamp
      ts1 = timestamp + STERN_TIMESTAMP_DELTA
      ts2 = timestamp + 2 * STERN_TIMESTAMP_DELTA

      credit_tx_id = apply_credits(charged_credits, merchant_id, ts0)
      Tx.add_boleto_fee(payment_id, merchant_id, charged_fees, ts1, cascade: false)
      Tx.add_boleto_payment(payment_id, merchant_id, amount, ts2, credit_tx_id, cascade: false)
    end

    def undo
      raise ParameterMissingError unless payment_id.present? && payment_id.is_a?(Numeric)

      credit_tx_id = Tx.find_by!(code: Tx.codes[:add_boleto_payment], uid: payment_id).credit_tx_id
      Tx.remove_credit(credit_tx_id) if credit_tx_id.present?
      Tx.remove_boleto_fee(payment_id)
      Tx.remove_boleto_payment(payment_id)
    end
  end
end
