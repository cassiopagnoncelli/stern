# frozen_string_literal: true

module Stern
  # Pay a merchant boleto.
  #
  # - apply credits
  # - add_boleto_fee
  # - add_boleto_payment
  class PayBoleto < BaseOperation
    UID = 8

    attr_accessor :payment_id, :merchant_id, :amount, :fee

    # Initialize the object, use `call` to perform the operation or `call_undo` to undo it.
    #
    # @param payment_id [Bigint] unique payment id
    # @param merchant_id [Bigint] merchant id
    # @param amount [Bigint] amount in cents
    # @param fee [Bigint] amount in cents
    def initialize(payment_id: nil, merchant_id: nil, amount: nil, fee: nil)
      self.payment_id = payment_id
      self.merchant_id = merchant_id
      self.amount = amount
      self.fee = fee
    end

    def perform(operation_id)
      raise ArgumentError if operation_id.blank?
      raise ArgumentError unless payment_id.present? && payment_id.is_a?(Numeric)
      raise ArgumentError unless merchant_id.present? && merchant_id.is_a?(Numeric)
      raise ArgumentError unless amount.present? && amount.is_a?(Numeric)
      raise ArgumentError unless fee.present? && fee.is_a?(Numeric)
      raise ArgumentError, "amount should not be zero" if amount.zero?

      credits = ::Stern.balance(merchant_id, :merchant_credit)
      charged_credits = [fee, credits].min
      charged_fees = fee - charged_credits

      credit_tx_id = apply_credits(charged_credits, merchant_id) if charged_credits.abs.positive?
      if charged_fees.abs.positive?
        Tx.add_boleto_fee(payment_id, merchant_id, charged_fees,
                          operation_id:,)
      end
      Tx.add_boleto_payment(payment_id, merchant_id, amount, credit_tx_id, operation_id:)
    end

    def perform_undo
      raise ArgumentError unless payment_id.present? && payment_id.is_a?(Numeric)

      credit_tx_id = Tx.find_by!(code: TXS[:add_boleto_payment], uid: payment_id).credit_tx_id
      Tx.remove_credit(credit_tx_id) if credit_tx_id.present?
      Tx.remove_boleto_fee(payment_id)
      Tx.remove_boleto_payment(payment_id)
    end
  end
end
