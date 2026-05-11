# frozen_string_literal: true

module Stern
  # Refund requires underlying payment to be reintegrated, that is, charge beneficiaries
  # back on the proportion of their splits before the refund is processed.
  class Refund < BaseOperation
    inputs :customer_id, :refund_id, :amount, :currency

    validates :customer_id, numericality: { greater_than: 0, only_integer: true }
    validates :refund_id, numericality: { greater_than: 0, only_integer: true }
    validates :amount, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      tuples = []
      tuples += tuples_for_pair(:confirm_refund, refund_id, refund_id, currency)
      tuples += tuples_for_pair(:settle_refund, refund_id, customer_id, currency)
      tuples
    end

    def perform(operation_id)
      EntryPair.add_confirm_refund(refund_id, refund_id, refund_id, amount, currency, operation_id:)
      EntryPair.add_settle_refund(refund_id, refund_id, customer_id, amount, currency, operation_id:)
    end
  end
end
