# frozen_string_literal: true

module Stern
  class ChargePix < BaseOperation
    include ActiveModel::Validations

    inputs :charge_id, :payment_id, :merchant_id, :customer_id, :amount, :currency

    validates :charge_id, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :payment_id, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :merchant_id, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :customer_id, numericality: { greater_than: 0, only_integer: true, allow_nil: true }
    validates :amount, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      tuples_for_pair(:charge_pix, payment_id, payment_id, currency)
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      EntryPair.add_charge_pix(payment_id, payment_id, amount, currency, operation_id:)
    end
  end
end
