# frozen_string_literal: true

module Stern
  # Expire a call option.
  class CallExpire < BaseOperation
    include ActiveModel::Validations

    attr_accessor :call_option_id, :customer_id, :currency, :amount

    validates :call_option_id, presence: true, numericality: { other_than: 0 }
    validates :customer_id, presence: true, numericality: { other_than: 0 }
    validates :currency, presence: true, allow_blank: false, allow_nil: false
    validates :amount, presence: true

    UnknownCurrencyError = Class.new(StandardError)

    # Initialize the object, use `call` to perform the operation or `call_undo` to undo it.
    #
    # @param call_option_id [Bigint] unique call option id
    # @param customer_id [Bigint] customer id
    # @param currency [Str] curreny code (eg. usd, eur, btc)
    # @param amount [Bigint] amount expired from the call option
    def initialize(call_option_id: nil, customer_id: nil, currency: nil, amount: nil)
      self.call_option_id = call_option_id
      self.customer_id = customer_id
      self.currency = currency.strip.downcase.presence
      self.amount = amount
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      raise UnknownCurrencyError unless currency.presence&.in?(%w[usd])

      EntryPair.add_call_expire_usd(call_option_id, customer_id, amount, nil, operation_id:) if amount.present?
    end

    def perform_undo
      raise ArgumentError if invalid?(:undo)

      if EntryPair.find_by(code: ENTRY_PAIRS[:add_call_expire_usd], uid: call_option_id).present?
        EntryPair.remove_call_expire_usd(call_option_id)
      end
    end
  end
end
