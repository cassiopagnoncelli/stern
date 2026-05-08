# frozen_string_literal: true

module Stern
  class Deallocate < BaseOperation
    inputs :customer_id, :currency

    validates :customer_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      tuples_for_pair(:allocate_customer, customer_id, customer_id, currency)
    end

    def perform(operation_id)
      amount = BalanceQuery.new(
        gid: customer_id,
        book_id: :customer_allocation,
        currency:,
        timestamp: Time.current,
      ).call
      return if amount.zero?

      EntryPair.add_allocate_customer(customer_id, customer_id, -amount, currency, operation_id:)
    end
  end
end
