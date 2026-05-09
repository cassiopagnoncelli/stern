# frozen_string_literal: true

module Stern
  # Admin-only ledger overlay between `<stakeholder>_adjusted` and
  # `<stakeholder>_available`. A positive amount credits available against
  # adjusted; a negative amount reverses the move. Both directions are
  # intentional — `AdjustBalance` is the wildcard "manual correction" tool,
  # not a normal-flow op.
  #
  # No backstops, by design. Neither `*_adjusted` nor `*_available` is
  # `non_negative`, and there is no `runtime_check`: the op will not refuse
  # to run, even when the result drives `*_available` below zero. That is
  # the whole point of an admin override.
  #
  # Downstream consequences are the caller's responsibility. A negative
  # `AdjustBalance` that leaves `*_available` negative will cause every op
  # that drains it (`LockBalance`, `WithholdBalance`, `LockWithdrawal`,
  # `Transfer`, fee charges, refunds, etc.) to raise `InsufficientFunds` or
  # `BalanceNonNegativeViolation` until the deficit is restored.
  #
  # Recommended use: invoke only from admin contexts (rake tasks, admin UI,
  # console under change control). Not safe to expose to end-user flows.
  class AdjustBalance < BaseOperation
    inputs :merchant_id, :customer_id, :partner_id, :amount, :currency

    validates :merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :customer_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :merchant_id, :customer_id, :partner_id
    validates :amount, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    performs_stakeholder_pair "adjust_%{type}_balance"
  end
end
