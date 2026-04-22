# frozen_string_literal: true

module Stern
  # Chargeback balance of customer's account.
  class ChargePix < BaseOperation
    include ActiveModel::Validations

    inputs :charge_id, :merchant_id, :customer_id, :amount, :currency

    validates :charge_id, presence: true, numericality: { other_than: 0 }
    validates :merchant_id, presence: true, numericality: { other_than: 0 }
    validates :amount, presence: true
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      tuples_for_pair(:pp_charge_pix, merchant_id, currency)
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      EntryPair.add_pp_charge_pix(charge_id, merchant_id, amount, currency, operation_id:)
    end
  end
end
