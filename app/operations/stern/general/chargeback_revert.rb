# frozen_string_literal: true

module Stern
  # Chargeback balance of customer's account.
  class ChargebackRevert < BaseOperation
    include ActiveModel::Validations

    attr_accessor :customer_id, :currency, :amount, :chargeback_id

    validates :chargeback_id, presence: true, numericality: { other_than: 0 }
    validates :customer_id, presence: true, numericality: { other_than: 0 }
    validates :currency, presence: true, allow_blank: false, allow_nil: false
    validates :amount, presence: true

    UnknownCurrencyError = Class.new(StandardError)

    # Initialize the object, use `call` to perform the operation or `call_undo` to undo it.
    #
    # @param chargeback_id [Bigint] unique chargeback id
    # @param customer_id [Bigint] customer id
    # @param currency [Str] curreny code (eg. usd, eur, btc)
    # @param amount [Bigint] amount given to customer
    def initialize(chargeback_id: nil, customer_id: nil, currency: nil, amount: nil)
      self.chargeback_id = chargeback_id
      self.customer_id = customer_id
      self.currency = currency.strip.downcase.presence
      self.amount = amount
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      raise UnknownCurrencyError unless currency.presence&.in?(%w[usd])

      EntryPair.add_customer_chargeback_revert_usd(chargeback_id, customer_id, amount, nil, operation_id:) if amount.present?
    end

    def perform_undo
      raise ArgumentError if invalid?(:undo)

      if EntryPair.find_by(code: ENTRY_PAIRS[:add_customer_chargeback_revert_usd], uid: chargeback_id).present?
        EntryPair.remove_customer_chargeback_revert_usd(chargeback_id)
      end
    end
  end
end
