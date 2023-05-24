# frozen_string_literal: true

module Stern
  # Charge merchant a settlement fee.
  #
  # - apply_credits
  # - add_settlement_fee
  class ChargeSettlementFee < BaseOperation
    UID = 2

    attr_accessor :settlement_id, :merchant_id, :fee

    # Initialize the object, use `call` to perform the operation or `call_undo` to undo it.
    #
    # @param settlement_id [Bigint] unique settlement id
    # @param merchant_id [Bigint] merchant id
    # @param fee [Bigint] amount in cents
    def initialize(settlement_id: nil, merchant_id: nil, fee: nil)
      @settlement_id = settlement_id
      @merchant_id = merchant_id
      @fee = fee
    end

    def perform(operation_id)
      raise ArgumentError unless operation_id.present?
      raise ArgumentError unless settlement_id.present? && settlement_id.is_a?(Numeric)
      raise ArgumentError unless merchant_id.present? && merchant_id.is_a?(Numeric)
      raise ArgumentError unless fee.present? && fee.is_a?(Numeric)
      raise ArgumentError, "fee should not be zero" if fee.positive?

      credits = ::Stern.balance(merchant_id, :merchant_credit)
      charged_credits = [fee, credits].min
      charged_fees = fee - charged_credits

      credit_tx_id = apply_credits(charged_credits, merchant_id)
      Tx.add_settlement_fee(settlement_id, merchant_id, charged_fees, credit_tx_id, operation_id:)
    end

    def perform_undo
      raise ArgumentError unless payment_id.present? && payment_id.is_a?(Numeric)

      credit_tx_id = Tx.find_by!(code: TXS[:add_boleto_fee], uid: payment_id).credit_tx_id
      Tx.remove_credit(credit_tx_id) if credit_tx_id.present?
      Tx.remove_boleto_fee(payment_id)
    end
  end
end
