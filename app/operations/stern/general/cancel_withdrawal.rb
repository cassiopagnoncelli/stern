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

    def target_tuples
      stakeholder_id, stakeholder_type = stakeholder_for

      tuples_for_pair("cancel_withdrawal_#{stakeholder_type}".to_sym, stakeholder_id, stakeholder_id, currency)
    end

    # Friendly pre-check that runs under the advisory lock. The DB-level
    # backstop on `wdw_*_locked` (when flagged `non_negative`) would translate
    # the same condition into `BalanceNonNegativeViolation`; we raise the
    # parent `InsufficientFunds` here so callers can rescue both layers
    # uniformly.
    def runtime_check
      stakeholder_id, stakeholder_type = stakeholder_for
      locked = locked_balance(stakeholder_id, stakeholder_type)
      return if amount <= locked

      raise ::Stern::InsufficientFunds,
        "cancel_withdrawal amount #{amount} exceeds locked balance #{locked}"
    end

    def perform(operation_id)
      stakeholder_id, stakeholder_type = stakeholder_for

      EntryPair.public_send(
        "add_cancel_withdrawal_#{stakeholder_type}".to_sym,
        stakeholder_id,
        stakeholder_id,
        amount,
        currency,
        operation_id:,
      )
    end

    private

    def locked_balance(stakeholder_id, stakeholder_type)
      BalanceQuery.new(
        gid: stakeholder_id,
        book_id: "wdw_#{stakeholder_type}_locked".to_sym,
        currency:,
        timestamp: Time.current
      ).call
    end
  end
end
