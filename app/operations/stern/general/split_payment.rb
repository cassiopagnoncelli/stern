# frozen_string_literal: true

module Stern
  class SplitPayment < BaseOperation
    include ActiveModel::Validations

    inputs :payment_id, :merchant_id, :partner_id, :amount, :currency

    validates :payment_id, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :amount, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      if merchant_id.present?
        tuples_for_pair(:split_payment_merchant, merchant_id, merchant_id, currency)
      elsif partner_id.present?
        tuples_for_pair(:split_payment_partner, partner_id, partner_id, currency)
      else
        []
      end
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?
      raise ArgumentError if [merchant_id, partner_id].compact.count != 1

      if merchant_id.present?
        EntryPair.add_split_payment_merchant(payment_id, merchant_id, amount, currency, operation_id:)
      elsif partner_id.present?
        EntryPair.add_split_payment_partner(payment_id, partner_id, amount, currency, operation_id:)
      end
    end
  end
end
