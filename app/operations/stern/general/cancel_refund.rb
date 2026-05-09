# frozen_string_literal: true

module Stern
  # Releases an in-flight refund lock back to the funder's available balance.
  # Inverse of `ReintegratePayment` for refunds (forward direction:
  # `refund_locked → <funder>_available`). Used when the gateway declines a
  # refund between `ReintegratePayment` and `Refund` (confirm + settle). Once
  # `Refund` has run, `refund_locked` for that refund has drained into
  # `refund_confirmed` and this op no longer applies — use `ReverseRefund`
  # for post-settlement reversals.
  #
  # Funder identity (merchant vs partner) must match the side that locked the
  # refund — `cancel_refund_merchant` undoes `lock_refund_merchant`,
  # `cancel_refund_partner` undoes `lock_refund_partner`. The DB-level
  # `non_negative` backstop on `refund_locked` enforces that the cancel
  # cannot exceed what was locked at this `refund_id`, but does not enforce
  # which funder the lock came from — callers must pass the right one.
  class CancelRefund < BaseOperation
    inputs :merchant_id, :partner_id, :refund_id, :amount, :currency

    validates :merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :merchant_id, :partner_id
    validates :refund_id, numericality: { greater_than: 0, only_integer: true }
    validates :amount, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    performs_stakeholder_pair "cancel_refund_%{type}",
      sub_gid: :refund_id,
      add_gid: :resolved,
      entry_uid: :resolved,
      entry_gid: :refund_id,
      requires_balance: { book: :refund_locked, label: "locked balance", gid: :refund_id }
  end
end
