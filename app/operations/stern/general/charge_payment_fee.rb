# frozen_string_literal: true

module Stern
  class ChargePaymentFee < BaseOperation
    include ActiveModel::Validations

    PAYMENT_METHODS = %w[bank_transfer credit_card debit_card wallet pix].freeze

    inputs :merchant_id, :customer_id, :partner_id, :payment_id, :method, :amount, :currency

    validates :merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :customer_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :payment_id, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :method, presence: true, inclusion: { in: PAYMENT_METHODS }
    validates :amount, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      if merchant_id.present?
        tuples_for_pair("charge_#{method}_fee_merchant".to_sym, merchant_id, payment_id, currency)
      elsif customer_id.present?
        tuples_for_pair("charge_#{method}_fee_customer".to_sym, customer_id, payment_id, currency)
      elsif partner_id.present?
        tuples_for_pair("charge_#{method}_fee_partner".to_sym, partner_id, payment_id, currency)
      else
        []
      end
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?
      raise ArgumentError if [merchant_id, customer_id, partner_id].compact.count != 1

      if merchant_id.present?
        EntryPair.public_send("add_charge_#{method}_fee_merchant".to_sym, merchant_id, payment_id, amount, currency, operation_id:)
      elsif customer_id.present?
        EntryPair.public_send("add_charge_#{method}_fee_customer".to_sym, customer_id, payment_id, amount, currency, operation_id:)
      elsif partner_id.present?
        EntryPair.public_send("add_charge_#{method}_fee_partner".to_sym, partner_id, payment_id, amount, currency, operation_id:)
      end
    end
  end
end
