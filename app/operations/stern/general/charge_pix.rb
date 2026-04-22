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

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      EntryPair.add_pp_charge_pix(charge_id, merchant_id, amount, operation_id:) if amount.present?
    end

    private

    def normalize_inputs
      self.currency = cur(currency, result: :index) if currency
    end
  end
end
