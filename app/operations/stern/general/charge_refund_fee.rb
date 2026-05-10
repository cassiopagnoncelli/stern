# frozen_string_literal: true

module Stern
  # Charges a refund fee against a stakeholder's `*_available`, optionally
  # drawing from `*_credit` first to reduce out-of-pocket.
  #
  # A negative `amount` reverses a previously-charged fee — the same entry
  # pair is emitted with flipped signs. Reverse-refund callers rely on this
  # idiom because `ReverseRefund` only unwinds the underlying fund movement,
  # not the fee. Credit application is intentionally skipped on the reversal
  # path: the credit redemption from the original charge is its own movement
  # and is not undone here.
  class ChargeRefundFee < BaseOperation
    inputs :merchant_id, :partner_id, :amount, :currency

    validates :merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :merchant_id, :partner_id
    validates :amount, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    performs_stakeholder_pair "charge_refund_fee_%{type}",
      requires_credit_application: true
  end
end
