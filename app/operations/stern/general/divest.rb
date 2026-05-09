# frozen_string_literal: true

module Stern
  class Divest < BaseOperation
    inputs :investment_id, :customer_id, :currency, :allow_overdraft

    validates :investment_id, numericality: { greater_than: 0, only_integer: true }
    validates :customer_id, numericality: { greater_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false
    validates :allow_overdraft, inclusion: { in: [ true, false ] }

    def normalize_inputs
      self.allow_overdraft = false if allow_overdraft.nil?
    end

    def target_tuples
      tuples_for_pair(:investment_trade_operation, investment_id, customer_id, currency)
    end

    def perform(operation_id)
      amount = BalanceQuery.new(gid: investment_id, book_id: :customer_investment, currency:, timestamp: Time.current).call
      return if amount.zero?
      return if !allow_overdraft && amount.negative?

      EntryPair.add_investment_trade_operation(customer_id, investment_id, -amount, currency, operation_id:)
    end
  end
end
