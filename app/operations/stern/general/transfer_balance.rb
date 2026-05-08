# frozen_string_literal: true

module Stern
  class TransferBalance < BaseOperation
    inputs :from_merchant_id, :from_customer_id, :from_partner_id, :to_merchant_id, :to_customer_id, :to_partner_id, :amount, :currency

    validates :from_merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :from_customer_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :from_partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :from_merchant_id, :from_customer_id, :from_partner_id
    validates :to_merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :to_customer_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :to_partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :to_merchant_id, :to_customer_id, :to_partner_id
    validate do
      errors.add(:base, "cannot transfer to self") if
        (from_merchant_id.present? && from_merchant_id == to_merchant_id) ||
        (from_customer_id.present? && from_customer_id == to_customer_id) ||
        (from_partner_id.present? && from_partner_id == to_partner_id)
    end
    validates :amount, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      tuples = []

      if from_merchant_id.present?
        tuples += tuples_for_pair(:merchant_available, from_merchant_id, from_merchant_id, currency)
      elsif from_customer_id.present?
        tuples += tuples_for_pair(:customer_available, from_customer_id, from_customer_id, currency)
      elsif from_partner_id.present?
        tuples += tuples_for_pair(:partner_available, from_partner_id, from_partner_id, currency)
      end

      if to_merchant_id.present?
        tuples += tuples_for_pair(:merchant_available, to_merchant_id, to_merchant_id, currency)
      elsif to_customer_id.present?
        tuples += tuples_for_pair(:customer_available, to_customer_id, to_customer_id, currency)
      elsif to_partner_id.present?
        tuples += tuples_for_pair(:partner_available, to_partner_id, to_partner_id, currency)
      end

      tuples
    end

    def perform(operation_id)
      if from_merchant_id.present?
        EntryPair.add_merchant_available(from_merchant_id, from_merchant_id, -amount, currency, operation_id:)
      elsif from_customer_id.present?
        EntryPair.add_customer_available(from_customer_id, from_customer_id, -amount, currency, operation_id:)
      elsif from_partner_id.present?
        EntryPair.add_partner_available(from_partner_id, from_partner_id, -amount, currency, operation_id:)
      end

      if to_merchant_id.present?
        EntryPair.add_merchant_available(to_merchant_id, to_merchant_id, amount, currency, operation_id:)
      elsif to_customer_id.present?
        EntryPair.add_customer_available(to_customer_id, to_customer_id, amount, currency, operation_id:)
      elsif to_partner_id.present?
        EntryPair.add_partner_available(to_partner_id, to_partner_id, amount, currency, operation_id:)
      end
    end
  end
end
