# frozen_string_literal: true

module Stern
  class Divest < BaseOperation
    inputs :investment_id, :customer_id, :currency, :allow_overdraft

    attr_accessor :amount

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

    # Reads the per-investment balance under the operation's advisory lock and
    # raises `Stern::InsufficientFunds` when it is negative and overdraft is
    # disallowed. A zero balance is left in place; `perform` skips the write so
    # repeated divests of an already-drained investment stay idempotent without
    # producing empty entry pairs.
    def runtime_check
      balance = BalanceQuery.new(
        gid: investment_id,
        book_id: :customer_investment,
        currency:,
        timestamp: Time.current
      ).call

      if !allow_overdraft && balance.negative?
        raise ::Stern::InsufficientFunds,
          "divest cannot drain negative customer_investment balance #{balance} without allow_overdraft"
      end

      self.amount = balance
    end

    def perform(operation_id)
      return if amount.zero?

      EntryPair.add_investment_trade_operation(customer_id, investment_id, -amount, currency, operation_id:)
    end
  end
end
