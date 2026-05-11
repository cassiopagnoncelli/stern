# frozen_string_literal: true

module Stern
  class Trade < BaseOperation
    inputs :investment_id, :amount, :fee, :currency

    validates :investment_id, numericality: { greater_than: 0, only_integer: true }
    validates :amount, presence: true, numericality: { only_integer: true }
    validates :fee, presence: true, numericality: { only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      tuples = []
      tuples += tuples_for_pair(:investment_trade, investment_id, investment_id, currency) unless amount.zero?
      tuples += tuples_for_pair(:investment_trade_fee, investment_id, investment_id, currency) unless fee.zero?
      tuples
    end

    def perform(operation_id)
      EntryPair.add_investment_trade(investment_id, investment_id, investment_id, amount, currency, operation_id:) unless amount.zero?
      EntryPair.add_investment_trade_fee(investment_id, investment_id, investment_id, -fee, currency, operation_id:) unless fee.zero?
    end
  end
end
