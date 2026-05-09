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

    def target_tuples
      stakeholder_id, stakeholder_type = stakeholder_for

      tuples_for_pair("reverse_withdrawal_#{stakeholder_type}".to_sym, stakeholder_id, stakeholder_id, currency)
    end

    def runtime_check
      stakeholder_id, stakeholder_type = stakeholder_for

      require_sufficient_balance!(
        book_id: "wdw_#{stakeholder_type}_confirmed".to_sym,
        gid: stakeholder_id,
        currency:,
        amount:,
        op_label: "reverse_withdrawal",
        balance_label: "confirmed balance",
      )
    end

    def perform(operation_id)
      stakeholder_id, stakeholder_type = stakeholder_for

      EntryPair.public_send(
        "add_reverse_withdrawal_#{stakeholder_type}".to_sym,
        stakeholder_id,
        stakeholder_id,
        amount,
        currency,
        operation_id:,
      )
    end
  end
end
