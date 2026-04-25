# frozen_string_literal: true

module Stern
  class ChargeManual < BaseOperation
    include ActiveModel::Validations

    inputs :charge_id, :payment_id, :customer_id, :amount, :currency, :fee

    validates :charge_id, presence: true, numericality: { other_than: 0 }
    validates :payment_id, presence: true, numericality: { other_than: 0 }
    validates :customer_id, numericality: { greater_than: 0, only_integer: true, allow_nil: true }
    validates :amount, presence: true
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      tuples = tuples_for_pair(:pay_manual, charge_id, currency)
      tuples = tuples_for_pair(:pp_charge_manual, customer_id, currency)
      tuples += customer_id ? tuples_for_pair(:identified_customer, customer_id, currency)
                            : tuples_for_pair(:unidentified_customer, customer_id, currency)
      tuples
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      # Operational info pairs.
      EntryPair.add_pay_manual(charge_id, payment_id, amount, currency, operation_id:)

      # Accounting info pairs.
      EntryPair.add_pp_charge_manual(charge_id, payment_id, amount, currency, operation_id:)
      EntryPair.add_pp_charge(charge_id, payment_id, amount, currency, operation_id:)
      if customer_id
        EntryPair.add_charge_identified_customer(charge_id, customer_id, amount, currency, operation_id:)
      else
        EntryPair.add_charge_unidentified_customer(charge_id, 1, amount, currency, operation_id:)
      end
    end
  end
end
