# frozen_string_literal: true

module Stern
  # Exercise a put option.
  class PutExercise < BaseOperation
    include ActiveModel::Validations

    attr_accessor :put_option_id, :customer_id, :currency, :amount, :payout

    validates :put_option_id, presence: true, numericality: { other_than: 0 }
    validates :customer_id, presence: true, numericality: { other_than: 0 }
    validates :currency, presence: true, allow_blank: false, allow_nil: false
    validates :amount, presence: true
    validates :payout, presence: true

    UnknownCurrencyError = Class.new(StandardError)

    # Initialize the object, use `call` to perform the operation or `call_undo` to undo it.
    #
    # @param put_option_id [Bigint] unique put option id
    # @param customer_id [Bigint] customer id
    # @param currency [Str] curreny code (eg. usd, eur, btc)
    # @param amount [Bigint] amount placed on the put option
    # @param payout [Bigint] payout amount
    def initialize(put_option_id: nil, customer_id: nil, currency: nil, amount: nil, payout: nil)
      self.put_option_id = put_option_id
      self.customer_id = customer_id
      self.currency = currency.strip.downcase.presence
      self.amount = amount
      self.payout = payout
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      raise UnknownCurrencyError unless currency.presence&.in?(%w[usd])

      EntryPair.add_handle_payback_put_usd(put_option_id, customer_id, amount, nil, operation_id:) if amount.present?
      EntryPair.add_payout_put_usd(put_option_id, customer_id, payout, nil, operation_id:) if payout.present?
      EntryPair.add_bops_trade_pl_usd(put_option_id, customer_id, payout, nil, operation_id:) if payout.present?
    end

    def perform_undo
      raise ArgumentError if invalid?(:undo)

      if EntryPair.find_by(code: ENTRY_PAIRS[:add_handle_payback_put_usd], uid: put_option_id).present?
        EntryPair.remove_handle_payback_put_usd(put_option_id)
      end
      if EntryPair.find_by(code: ENTRY_PAIRS[:add_payout_put_usd], uid: put_option_id).present?
        EntryPair.remove_payout_put_usd(put_option_id)
      end
      if EntryPair.find_by(code: ENTRY_PAIRS[:add_bops_trade_pl_usd], uid: put_option_id).present?
        EntryPair.remove_bops_trade_pl_usd(put_option_id)
      end
    end
  end
end
