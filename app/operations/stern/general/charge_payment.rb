# frozen_string_literal: true

module Stern
  class ChargePayment < BaseOperation
    include ActiveModel::Validations

    PAYMENT_METHODS = %w[bank_transfer credit_card wallet pix].freeze

    inputs :charge_id, :payment_id, :method, :amount, :currency

    validates :charge_id, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :payment_id, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :method, presence: true, inclusion: { in: PAYMENT_METHODS }
    validates :amount, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      tuples_for_pair("charge_#{method}".to_sym, charge_id, payment_id, currency)
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      EntryPair.public_send("add_charge_#{method}".to_sym, charge_id, payment_id, amount, currency, operation_id:)
    end
  end
end
