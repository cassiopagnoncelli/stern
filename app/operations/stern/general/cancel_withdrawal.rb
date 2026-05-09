# frozen_string_literal: true

module Stern
  # Releases an in-flight withdrawal lock back to the stakeholder's available
  # balance. Inverse of `LockWithdrawal` (forward direction:
  # `wdw_*_locked → *_available`). Use only before `ConfirmWithdrawal`; once
  # confirmed, use `ReverseWithdrawal` instead.
  class CancelWithdrawal < BaseOperation
    inputs :merchant_id, :partner_id, :customer_id, :amount, :currency

    validates :merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :customer_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :merchant_id, :customer_id, :partner_id
    validates :amount, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    performs_stakeholder_pair "cancel_withdrawal_%{type}",
      requires_balance: { book: "wdw_%{type}_locked", label: "locked balance" }
  end
end
