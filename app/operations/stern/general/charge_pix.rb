# frozen_string_literal: true

module Stern
  class ChargePix < BaseOperation
    include ActiveModel::Validations

    inputs :charge_id, :payment_id, :merchant_id, :customer_id, :amount, :currency, :fee

    validates :charge_id, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :payment_id, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :merchant_id, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :customer_id, numericality: { greater_than: 0, only_integer: true, allow_nil: true }
    validates :amount, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      tuples = tuples_for_pair(:charge_with_pix, charge_id, charge_id, currency)
      tuples += tuples_for_pair(:payment_with_pix, payment_id, payment_id, currency)
      tuples += tuples_for_pair(:merchant_payment, merchant_id, merchant_id, currency)
      tuples += customer_id.present? ?
        tuples_for_pair(:identified_customer_payment, customer_id, customer_id, currency) :
        tuples_for_pair(:unidentified_customer_payment, 1, 1, currency)
      tuples
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      # Operational info pairs.
      EntryPair.add_payment_with_pix(payment_id, payment_id, amount, currency, operation_id:)

      # Accounting
      EntryPair.add_charge_with_pix(charge_id, charge_id, amount, currency, operation_id:)
      EntryPair.add_merchant_payment(merchant_id, merchant_id, amount, currency, operation_id:)
      if customer_id.present?
        EntryPair.add_identified_customer_payment(customer_id, customer_id, amount, currency, operation_id:)
      else
        EntryPair.add_unidentified_customer_payment(customer_id, 1, amount, currency, operation_id:)
      end
    end
  end
end
