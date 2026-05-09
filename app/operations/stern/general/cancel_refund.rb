# frozen_string_literal: true

module Stern
  # Releases an in-flight refund lock back to the funder's available balance.
  # Inverse of `ReintegratePayment` for refunds (forward direction:
  # `refund_locked → <funder>_available`). Used when the gateway declines a
  # refund between `ReintegratePayment` and `Refund` (confirm + settle). Once
  # `Refund` has run, `refund_locked` for that refund has drained into
  # `refund_confirmed` and this op no longer applies.
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

    def target_tuples
      stakeholder_id, stakeholder_type = stakeholder_for

      tuples_for_pair("cancel_refund_#{stakeholder_type}".to_sym, refund_id, stakeholder_id, currency)
    end

    # Friendly pre-check that runs under the advisory lock. The DB-level
    # backstop on `refund_locked` (flagged `non_negative`) would translate
    # the same condition into `BalanceNonNegativeViolation`; we raise the
    # parent `InsufficientFunds` here so callers can rescue both layers
    # uniformly.
    def runtime_check
      locked = locked_balance
      return if amount <= locked

      raise ::Stern::InsufficientFunds,
        "cancel_refund amount #{amount} exceeds locked balance #{locked}"
    end

    def perform(operation_id)
      stakeholder_id, stakeholder_type = stakeholder_for

      EntryPair.public_send(
        "add_cancel_refund_#{stakeholder_type}".to_sym,
        stakeholder_id,
        refund_id,
        amount,
        currency,
        operation_id:,
      )
    end

    private

    def locked_balance
      BalanceQuery.new(
        gid: refund_id,
        book_id: :refund_locked,
        currency:,
        timestamp: Time.current
      ).call
    end
  end
end
