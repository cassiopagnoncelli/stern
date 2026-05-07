# frozen_string_literal: true

module Stern
  class Trade < BaseOperation
    inputs :trade_id, :customer_id, :amount, :fee, :currency

    validates :trade_id, numericality: { greater_than: 0, only_integer: true }
    validates :customer_id, numericality: { greater_than: 0, only_integer: true }
    validates :amount, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      tuples = tuples_for_pair(:trade, nil, customer_id, currency)
      tuples += tuples_for_pair(:trade_fee, nil, customer_id, currency)
      tuples
    end

    def perform(operation_id)
      EntryPair.add_trade(trade_id, customer_id, amount, currency, operation_id:)
      EntryPair.add_trade_fee(trade_id, customer_id, fee, currency, operation_id:)
    end
  end
end
