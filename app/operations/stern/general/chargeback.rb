# frozen_string_literal: true

module Stern
  # Chargeback requires underlying payment to be reintegrated, that is, charge beneficiaries
  # back on the proportion of their splits before the chargeback is processed.
  class Chargeback < BaseOperation
    inputs :customer_id, :chargeback_id, :currency

    validates :customer_id, numericality: { greater_than: 0, only_integer: true }
    validates :chargeback_id, numericality: { greater_than: 0, only_integer: true }
    validates :amount, presence: true, numericality: { only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      tuples_for_pair(:confirm_chargeback, chargeback_id, chargeback_id, currency)
    end

    def perform(operation_id)
      EntryPair.add_confirm_chargeback(chargeback_id, chargeback_id, amount, currency, operation_id:)
    end
  end
end
