# frozen_string_literal: true

module Stern
  class SettleMerchantBalance < BaseOperation
    include ActiveModel::Validations

    inputs :merchant_id, :amount, :currency

    validates :merchant_id, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :amount, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      tuples_for_pair(:settle_merchant_balance, merchant_id, merchant_id, currency)
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      EntryPair.add_settle_merchant_balance(merchant_id, merchant_id, amount, currency, operation_id:)
    end
  end
end
