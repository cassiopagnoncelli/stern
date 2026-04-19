# frozen_string_literal: true

module Stern
  # Refund balance of customer's account.
  class Refund < BaseOperation
    include ActiveModel::Validations

    attr_accessor :customer_id, :currency, :amount, :refund_id

    validates :refund_id, presence: true, numericality: { other_than: 0 }
    validates :customer_id, presence: true, numericality: { other_than: 0 }
    validates :currency, presence: true, allow_blank: false, allow_nil: false
    validates :amount, presence: true

    UnknownCurrencyError = Class.new(StandardError)

    # Initialize the object, use `call` to perform the operation or `call_undo` to undo it.
    #
    # @param refund_id [Bigint] unique refund id
    # @param customer_id [Bigint] customer id
    # @param currency [Str] curreny code (eg. usd, eur, btc)
    # @param amount [Bigint] amount given to customer
    def initialize(refund_id: nil, customer_id: nil, currency: nil, amount: nil)
      self.refund_id = refund_id
      self.customer_id = customer_id
      self.currency = currency.strip.downcase.presence
      self.amount = amount
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      raise UnknownCurrencyError unless currency.presence&.in?(%w[usd])

      EntryPair.add_customer_refund_usd(refund_id, customer_id, amount, nil, operation_id:) if amount.present?
    end

    def perform_undo
      raise ArgumentError if invalid?(:undo)

      if EntryPair.find_by(code: ENTRY_PAIRS[:add_customer_refund_usd], uid: refund_id).present?
        EntryPair.remove_customer_refund_usd(refund_id)
      end
    end
  end
end
