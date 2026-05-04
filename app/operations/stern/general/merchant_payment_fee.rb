# frozen_string_literal: true

module Stern
  class MerchantPaymentFee < BaseOperation
    include ActiveModel::Validations

    inputs :merchant_id, :fee, :currency

    validates :merchant_id, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :fee, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      tuples_for_pair(:merchant_payment_fee, merchant_id, merchant_id, currency)
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      # Operational info pairs.
      EntryPair.add_merchant_payment_fee(merchant_id, merchant_id, fee, currency, operation_id:)
    end
  end
end
