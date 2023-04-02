module Stern
  class PayBoleto < BaseOperation
    attr_accessor :payment_id, :merchant_id, :amount, :fee

    def initialize(payment_id: nil, merchant_id: nil, amount: nil, fee: nil)
      @payment_id = payment_id
      @merchant_id = merchant_id
      @amount = amount
      @fee = fee
    end

    # PayBoleto performs two transactions:
    # 1. add_boleto_payment: adds to merchant_balance book, removes from boleto_processed
    # 2. add_boleto_fee: use credits to determine payable fee before removing from merchant_balance
    #    book and adding to boleto_fee.
    #
    # @param payment_id [Bigint] unique payment id
    # @param merchant_id [Bigint] merchant id
    # @param amount [Bigint] amount in cents
    # @param fee [Bigint] amount in cents
    def perform
      raise ParameterMissingError unless payment_id.present? && payment_id.is_a?(Numeric)
      raise ParameterMissingError unless merchant_id.present? && merchant_id.is_a?(Numeric)
      raise ParameterMissingError unless amount.present? && amount.is_a?(Numeric)
      raise ParameterMissingError unless fee.present? && fee.is_a?(Numeric)
      raise AmountShouldNotBeZeroError if amount.zero?

      credits = ::Stern.balance(merchant_id, :merchant_credit)
      charged_credits = [fee, credits].min
      charged_fees = fee - charged_credits

      credit_tx_id = apply_credits(charged_credits, merchant_id)
      Tx.add_boleto_fee(payment_id, merchant_id, charged_fees)
      Tx.add_boleto_payment(payment_id, merchant_id, amount, credit_tx_id)
    end

    def undo
      raise ParameterMissingError unless payment_id.present? && payment_id.is_a?(Numeric)

      credit_tx_id = Tx.find_by!(code: TXS[:add_boleto_payment], uid: payment_id).credit_tx_id
      Tx.remove_credit(credit_tx_id) if credit_tx_id.present?
      Tx.remove_boleto_fee(payment_id)
      Tx.remove_boleto_payment(payment_id)
    end
  end
end
