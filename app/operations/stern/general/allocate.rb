# frozen_string_literal: true

module Stern
  class Allocate < BaseOperation
    inputs :customer_id, :amount, :currency

    validates :customer_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :amount, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      tuples_for_pair(:allocate_customer, customer_id, customer_id, currency)
    end

    def perform(operation_id)
      EntryPair.add_allocate_customer(customer_id, customer_id, amount, currency, operation_id:)
    end
  end
end
