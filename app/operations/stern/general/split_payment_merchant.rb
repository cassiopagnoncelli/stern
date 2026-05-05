# frozen_string_literal: true

module Stern
  class SplitPaymentMerchant < BaseOperation
    include ActiveModel::Validations

    inputs :payment_id, :merchant_id, :amount, :currency

    validates :payment_id, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :merchant_id, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :amount, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      tuples_for_pair(:split_payment_merchant, merchant_id, merchant_id, currency)
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      EntryPair.add_split_payment_merchant(payment_id, merchant_id, amount, currency, operation_id:)
    end
  end
end
