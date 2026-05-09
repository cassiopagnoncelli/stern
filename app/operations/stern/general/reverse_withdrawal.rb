# frozen_string_literal: true

module Stern
  # Reverses a previously confirmed withdrawal back to the stakeholder's
  # available balance (forward direction: `wdw_*_confirmed → *_available`).
  # Terminal step of the lock → cancel | confirm → reverse state machine
  # (canonical lifecycle: see the entry-pairs block in
  # `config/charts/general.yaml`). Used for post-settlement rejects; for
  # pre-settlement cancellation use `CancelWithdrawal`. Intentionally has
  # no `allow_overdraft` input (unlike `LockWithdrawal`): `wdw_*_confirmed`
  # non-negativity is the only safe rule for post-settlement reversals —
  # you cannot reverse more than was confirmed.
  class ReverseWithdrawal < BaseOperation
    inputs :merchant_id, :partner_id, :customer_id, :amount, :currency

    validates :merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :customer_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :merchant_id, :customer_id, :partner_id
    validates :amount, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    performs_stakeholder_pair "reverse_withdrawal_%{type}",
      requires_balance: { book: "wdw_%{type}_confirmed", label: "confirmed balance" }
  end
end
