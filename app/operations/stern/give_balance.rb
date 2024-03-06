# frozen_string_literal: true

module Stern
  # Give merchant away balance.
  #
  # - add_balance
  class GiveBalance < BaseOperation
    UID = 5

    attr_accessor :uid, :merchant_id, :amount

    # Initialize the object, use `call` to perform the operation or `call_undo` to undo it.
    #
    # @param uid [Bigint] unique id
    # @param merchant_id [Bigint] merchant id
    # @param amount [Bigint] amount in cents
    def initialize(uid: nil, merchant_id: nil, amount: nil)
      @uid = uid
      @merchant_id = merchant_id
      @amount = amount
    end

    def perform(operation_id)
      raise ArgumentError if operation_id.blank?
      raise ArgumentError unless uid.present? && uid.is_a?(Numeric)
      raise ArgumentError unless merchant_id.present? && merchant_id.is_a?(Numeric)
      raise ArgumentError unless amount.present? && amount.is_a?(Numeric)
      raise ArgumentError, "amount should not be zero" if amount.zero?

      Tx.add_balance(uid, merchant_id, amount, operation_id:)
    end

    def perform_undo
      raise ArgumentError unless uid.present? && uid.is_a?(Numeric)

      tx = Tx.find_by!(code: TXS[:add_balance], uid:)
      Tx.remove_balance(tx.id)
    end
  end
end
