# frozen_string_literal: true

module Stern
  # Redeems credit into the stakeholder's available balance
  # (`<stakeholder>_credit` → `<stakeholder>_available`). A negative amount
  # reverses the move and increases the credit book against the available
  # balance — semantically "add credit funded by the stakeholder's own cash."
  #
  # That overlaps with `AddCredit` in effect on the credit book, but the
  # counterparties differ: `AddCredit` debits the external `_credit_0` sink
  # (grant from outside the ledger), while negative `ApplyCredit` debits
  # `_available` (move from the stakeholder's own funds). Choose by which
  # counterparty reflects reality.
  #
  # Overdraft semantics. `ApplyCredit` has no `runtime_check`; the two
  # directions have asymmetric backstops:
  #
  # - Positive amount drains `*_credit`. `*_credit` is `non_negative`, so an
  #   over-debit is refused at the DB layer as `BalanceNonNegativeViolation`
  #   (no friendly `InsufficientFunds` wrapper).
  # - Negative amount drains `*_available`. `*_available` is **not**
  #   `non_negative` — an over-debit is silent and the caller is
  #   responsible for ensuring the stakeholder can fund the move.
  #
  # If you need a friendly pre-check on either direction, gate the call at
  # the caller (read the relevant book first) until this op grows an
  # `allow_overdraft` flag of its own.
  class ApplyCredit < BaseOperation
    inputs :merchant_id, :customer_id, :partner_id, :amount, :currency

    validates :merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :customer_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :merchant_id, :customer_id, :partner_id
    validates :amount, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    performs_stakeholder_pair "apply_%{type}_credit"
  end
end
