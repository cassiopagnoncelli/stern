# frozen_string_literal: true

module Stern
  # Start a merchant settlement.
  #
  # - add_settlement_processing
  class OpenSettlement < BaseOperation
    UID = 7

    attr_accessor :settlement_id, :merchant_id, :amount

    # Initialize the object, use `call` to perform the operation or `call_undo` to undo it.
    #
    # @param settlement_id [Bigint] unique settlement id
    # @param merchant_id [Bigint] merchant id
    # @param amount [Bigint] amount in cents
    def initialize(settlement_id: nil, merchant_id: nil, amount: nil)
      self.settlement_id = settlement_id
      self.merchant_id = merchant_id
      self.amount = amount
    end

    def perform(operation_id)
      raise ArgumentError if operation_id.blank?
      raise ArgumentError unless settlement_id.present? && settlement_id.is_a?(Numeric)
      raise ArgumentError unless merchant_id.present? && merchant_id.is_a?(Numeric)
      raise ArgumentError unless amount.present? && amount.is_a?(Numeric)
      raise ArgumentError, "amount should not be zero" if amount.zero?

      Tx.add_settlement_processing(settlement_id, merchant_id, amount, nil, operation_id:)
    end

    def perform_undo
      raise ArgumentError unless settlement_id.present? && settlement_id.is_a?(Numeric)

      Tx.remove_settlement(settlement_id)
    end
  end
end
