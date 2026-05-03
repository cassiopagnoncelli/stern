# frozen_string_literal: true

module Stern
  class ChargePix < BaseOperation
    include ActiveModel::Validations

    inputs :charge_id, :payment_id, :customer_id, :amount, :currency, :fee

    validates :charge_id, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :payment_id, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :customer_id, numericality: { greater_than: 0, only_integer: true, allow_nil: true }
    validates :amount, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      tuples = tuples_for_pair(:charge_pix_payment, charge_id, currency)
      tuples
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      # Operational info pairs.
      EntryPair.add_charge_pix_payment(charge_id, payment_id, amount, currency, operation_id:)
    end
  end
end
