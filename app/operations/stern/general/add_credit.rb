# frozen_string_literal: true

module Stern
  class AddCredit < BaseOperation
    include ActiveModel::Validations

    inputs :merchant_id, :customer_id, :partner_id, :amount, :currency

    validates :merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :customer_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :amount, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false
    validates_exactly_one_of :merchant_id, :customer_id, :partner_id

    def target_tuples
      if merchant_id.present?
        tuples_for_pair(:merchant_credit, merchant_id, merchant_id, currency)
      elsif customer_id.present?
        tuples_for_pair(:customer_credit, customer_id, customer_id, currency)
      elsif partner_id.present?
        tuples_for_pair(:partner_credit, partner_id, partner_id, currency)
      else
        []
      end
    end

    def perform(operation_id)
      if merchant_id.present?
        EntryPair.add_merchant_credit(merchant_id, merchant_id, amount, currency, operation_id:)
      elsif customer_id.present?
        EntryPair.add_customer_credit(customer_id, customer_id, amount, currency, operation_id:)
      elsif partner_id.present?
        EntryPair.add_partner_credit(partner_id, partner_id, amount, currency, operation_id:)
      end
    end
  end
end
