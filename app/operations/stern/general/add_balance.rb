# frozen_string_literal: true

module Stern
  # Lock balance of customer's account.
  class AddBalance < BaseOperation
    include ActiveModel::Validations

    attr_accessor :merchant_id, :currency, :amount

    validates :merchant_id, presence: true, numericality: { other_than: 0 }
    validates :amount, presence: true
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    # Initialize the object, use `call` to perform the operation or `call_undo` to undo it.
    #
    # @param lock_id [Bigint] unique lock id 
    # @param merchant_id [Bigint] customer id
    # @param currency [Str] curreny code (eg. usd, eur, btc)
    # @param amount [Bigint] amount given to customer
    def initialize(merchant_id: nil, amount: nil, currency: nil)
      self.merchant_id = merchant_id
      self.amount = amount
      self.currency = cur(currency, result: :index)
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      EntryPair.add_merchant_balance(operation_id, merchant_id, amount, nil, operation_id:) if amount.present?
    end
  end
end
