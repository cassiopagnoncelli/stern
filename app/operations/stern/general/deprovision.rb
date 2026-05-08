# frozen_string_literal: true

module Stern
  class Deprovision < BaseOperation
    inputs :provision_id, :customer_id, :currency

    validates :provision_id, numericality: { greater_than: 0, only_integer: true }
    validates :customer_id, numericality: { greater_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      tuples_for_pair(:provision_trade_operation, provision_id, customer_id, currency)
    end

    def perform(operation_id)
      amount = BalanceQuery.new(gid: provision_id, book_id: :customer_provision, currency:, timestamp: Time.current).call
      return if amount.zero?

      EntryPair.add_provision_trade_operation(customer_id, provision_id, -amount, currency, operation_id:)
    end
  end
end
