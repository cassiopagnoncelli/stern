# frozen_string_literal: true

module Stern
  # Charge merchant the settlement amount.
  #
  # - apply_credits
  # - add_settlement_fee
  # - add_settlement
  class ChargeSettlement < BaseOperation
    UID = 3

    attr_accessor :settlement_id, :merchant_id, :amount, :fee

    # Initialize the object, use `call` to perform the operation or `call_undo` to undo it.
    #
    # @param settlement_id [Bigint] unique settlement id
    # @param merchant_id [Bigint] merchant id
    # @param amount [Bigint] amount in cents
    # @param fee [Bigint] amount in cents
    def initialize(settlement_id: nil, merchant_id: nil, amount: nil, fee: nil)
      @settlement_id = settlement_id
      @merchant_id = merchant_id
      @amount = amount
      @fee = fee
    end

    def perform(operation_id)
      raise ArgumentError unless operation_id.present?
      raise ArgumentError unless settlement_id.present? && settlement_id.is_a?(Numeric)
      raise ArgumentError unless merchant_id.present? && merchant_id.is_a?(Numeric)
      raise ArgumentError unless amount.present? && amount.is_a?(Numeric)
      raise ArgumentError unless fee.present? && fee.is_a?(Numeric)
      raise ArgumentError, "amount should not be zero" if amount.zero?

      credits = ::Stern.balance(merchant_id, :merchant_credit)
      charged_credits = [fee, credits].min
      charged_fees = fee - charged_credits

      credit_tx_id = apply_credits(charged_credits, merchant_id)
      Tx.add_settlement_fee(settlement_id, merchant_id, charged_fees, operation_id:)
      Tx.add_settlement(settlement_id, merchant_id, amount, credit_tx_id, operation_id:)
    end

    def perform_undo
      raise ArgumentError unless settlement_id.present? && settlement_id.is_a?(Numeric)

      credit_tx_id = Tx.find_by!(code: TXS[:add_settlement], uid: settlement_id).credit_tx_id

      Tx.remove_credit(credit_tx_id) if credit_tx_id.present?
      Tx.remove_settlement_fee(settlement_id)
      Tx.remove_settlement(settlement_id)
    end
  end
end
