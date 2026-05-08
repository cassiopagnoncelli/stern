# frozen_string_literal: true

module Stern
  class Provision < BaseOperation
    inputs :provision_id, :customer_id, :amount, :currency

    validates :provision_id, numericality: { greater_than: 0, only_integer: true }
    validates :customer_id, numericality: { greater_than: 0, only_integer: true }
    validates :amount, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      tuples_for_pair(:provision_customer_funds, customer_id, provision_id, currency)
    end

    def perform(operation_id)
      EntryPair.add_provision_customer_funds(customer_id, provision_id, amount, currency, operation_id:)
    end
  end
end
