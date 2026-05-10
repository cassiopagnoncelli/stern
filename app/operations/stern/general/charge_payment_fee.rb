# frozen_string_literal: true

module Stern
  # Charges a payment-method fee against a stakeholder's `*_available`,
  # optionally drawing from `*_credit` first to reduce out-of-pocket.
  #
  # A negative `amount` reverses a previously-charged fee — the same entry
  # pair is emitted with flipped signs. Reverse-refund / reverse-chargeback
  # callers rely on this idiom because `ReverseRefund` / `ReverseChargeback`
  # only unwind the underlying fund movement, not the fee. Credit
  # application is intentionally skipped on the reversal path: the credit
  # redemption from the original charge is its own movement and is not
  # undone here.
  class ChargePaymentFee < BaseOperation
    PAYMENT_METHODS = %w[bank_transfer credit_card debit_card wallet pix].freeze

    inputs :merchant_id, :customer_id, :partner_id, :payment_id, :payment_method, :amount, :currency

    validates :merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :customer_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :merchant_id, :customer_id, :partner_id
    validates :payment_id, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :payment_method, presence: true, inclusion: { in: PAYMENT_METHODS }
    validates :amount, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    performs_stakeholder_pair "charge_%{payment_method}_fee_%{type}",
      add_gid: :payment_id,
      requires_credit_application: true
  end
end
