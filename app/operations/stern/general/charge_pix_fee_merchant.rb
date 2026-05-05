# frozen_string_literal: true

module Stern
  class ChargePixFeeMerchant < BaseOperation
    include ActiveModel::Validations

    inputs :merchant_id, :fee, :currency

    validates :merchant_id, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :fee, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      tuples_for_pair(:charge_pix_fee_merchant, merchant_id, merchant_id, currency)
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      EntryPair.add_charge_pix_fee_merchant(merchant_id, merchant_id, fee, currency, operation_id:)
    end
  end
end
