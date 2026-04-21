# frozen_string_literal: true

module Stern
  # Chargeback balance of customer's account.
  class ChargePix < BaseOperation
    include ActiveModel::Validations

    attr_accessor :charge_id, :merchant_id, :customer_id, :amount, :currency

    validates :charge_id, presence: true, numericality: { other_than: 0 }
    validates :merchant_id, presence: true, numericality: { other_than: 0 }
    validates :amount, presence: true
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    # Initialize the object, use `call` to perform the operation or `call_undo` to undo it.
    #
    # @param charge_id [Bigint] unique chargeback id
    # @param customer_id [Bigint] customer id
    # @param currency [Str] curreny code (eg. usd, eur, btc)
    # @param amount [Bigint] amount given to customer
    def initialize(charge_id: nil, merchant_id: nil, customer_id: nil, amount: nil, currency: nil)
      self.charge_id = charge_id
      self.merchant_id = merchant_id
      self.customer_id = customer_id
      self.amount = amount
      self.currency = cur(currency, result: :index)
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      EntryPair.add_pp_charge_pix(charge_id, merchant_id, amount, nil, operation_id:) if amount.present?
    end
  end
end
