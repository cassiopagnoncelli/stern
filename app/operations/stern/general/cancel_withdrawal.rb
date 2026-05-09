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

    def runtime_check
      stakeholder_id, stakeholder_type = stakeholder_for

      require_sufficient_balance!(
        book_id: "wdw_#{stakeholder_type}_locked".to_sym,
        gid: stakeholder_id,
        currency:,
        amount:,
        op_label: "cancel_withdrawal",
        balance_label: "locked balance",
      )
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
  end
end
