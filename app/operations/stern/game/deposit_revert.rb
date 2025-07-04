# frozen_string_literal: true

module Stern
  class DepositRevert < BaseOperation
    include ActiveModel::Validations

    attr_accessor :deposit_id, :customer_id, :currency, :amount

    validates :deposit_id, presence: true, numericality: { other_than: 0 }
    validates :customer_id, presence: true, numericality: { other_than: 0 }
    validates :currency, presence: true, allow_blank: false, allow_nil: false
    validates :amount, presence: false

    UnknownCurrencyError = Class.new(StandardError)

    # Initialize the object, use `call` to perform the operation or `call_undo` to undo it.
    #
    # @param deposit_id [Bigint] unique deposit id
    # @param customer_id [Bigint] customer id
    # @param currency [Str] curreny code (eg. usd, eur, btc)
    # @param amount [Bigint] amount reverted from customer balance
    def initialize(deposit_id: nil, customer_id: nil, currency: nil, amount: nil)
      self.deposit_id = deposit_id
      self.customer_id = customer_id
      self.currency = currency.strip.downcase.presence
      self.amount = amount
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      raise UnknownCurrencyError unless currency.presence&.in?(%w[usd])

      EntryPair.add_customer_deposit_revert_usd(deposit_id, customer_id, amount, nil, operation_id:) if amount.present?
    end

    def perform_undo
      raise ArgumentError if invalid?(:undo)

      if EntryPair.find_by(code: ENTRY_PAIRS[:add_customer_deposit_revert_usd], uid: deposit_id).present?
        EntryPair.remove_customer_deposit_revert_usd(deposit_id)
      end
    end
  end
end
