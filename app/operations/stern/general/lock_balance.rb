# frozen_string_literal: true

module Stern
  class LockBalance < BaseOperation
    inputs :merchant_id, :customer_id, :partner_id, :amount, :currency

    validates :merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :customer_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :merchant_id, :customer_id, :partner_id
    validates :amount, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      if merchant_id.present?
        tuples_for_pair(:lock_merchant_balance, merchant_id, merchant_id, currency)
      elsif customer_id.present?
        tuples_for_pair(:lock_customer_balance, customer_id, customer_id, currency)
      elsif partner_id.present?
        tuples_for_pair(:lock_partner_balance, partner_id, partner_id, currency)
      else
        []
      end
    end

    def perform(operation_id)
      if merchant_id.present?
        EntryPair.add_lock_merchant_balance(merchant_id, merchant_id, amount, currency, operation_id:)
      elsif customer_id.present?
        EntryPair.add_lock_customer_balance(customer_id, customer_id, amount, currency, operation_id:)
      elsif partner_id.present?
        EntryPair.add_lock_partner_balance(partner_id, partner_id, amount, currency, operation_id:)
      end
    end
  end
end
