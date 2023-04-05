# frozen_string_literal: true

module Stern
  # Charges a merchant subscription from credits and/or merchant balance.
  #
  # - apply credits
  # - add_subscription
  class ChargeSubscription < BaseOperation
    attr_accessor :subs_charge_id, :merchant_id, :amount

    # Initialize the object, use `call` to perform the operation or `call_undo` to undo it.
    #
    # @param subs_charge_id [Bigint] unique subscription charge id
    # @param merchant_id [Bigint] merchant id
    # @param amount [Bigint] amount in cents
    def initialize(subs_charge_id: nil, merchant_id: nil, amount: nil)
      @subs_charge_id = subs_charge_id
      @merchant_id = merchant_id
      @amount = amount
    end

    def perform
      raise ArgumentError unless subs_charge_id.present? && subs_charge_id.is_a?(Numeric)
      raise ArgumentError unless merchant_id.present? && merchant_id.is_a?(Numeric)
      raise ArgumentError unless amount.present? && amount.is_a?(Numeric)
      raise ArgumentError, "amount should not be zero" if amount.zero?

      credits = ::Stern.balance(merchant_id, :merchant_credit)
      charged_credits = [amount, credits].min
      charged_subs = amount - charged_credits

      credit_tx_id = apply_credits(charged_credits, merchant_id)
      Tx.add_subscription(subs_charge_id, merchant_id, charged_subs, credit_tx_id)
    end

    def undo
      raise ArgumentError unless subs_charge_id.present? && subs_charge_id.is_a?(Numeric)

      credit_tx_id = Tx.find_by!(code: TXS[:add_subscription], uid: subs_charge_id).credit_tx_id

      Tx.remove_credit(credit_tx_id) if credit_tx_id.present?
      Tx.remove_subscription(subs_charge_id)
    end
  end
end
