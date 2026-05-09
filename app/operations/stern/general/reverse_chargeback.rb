# frozen_string_literal: true

module Stern
  # Reverses a previously confirmed chargeback (issuer overturned the dispute)
  # by recovering the recognized loss to the funder's available balance
  # (forward direction: `chargeback_loss -> *_available`). Single-pair direct
  # unwind in the same idiom as `ReverseWithdrawal`.
  #
  # Funder identity (merchant vs partner) was consumed at `lock_chargeback_*`
  # and drained into the fungible `chargeback_loss`, so it is not derivable
  # from `chargeback_id` alone — the caller must re-supply it.
  #
  # `chargeback_loss` is `non_negative`, so the DB enforces that cumulative
  # reversals on a chargeback_id cannot exceed the originally confirmed
  # amount; the friendly `runtime_check` raises `InsufficientFunds` ahead of
  # the trigger so callers see the same error shape as `ReverseWithdrawal`.
  class ReverseChargeback < BaseOperation
    inputs :merchant_id, :partner_id, :chargeback_id, :amount, :currency

    validates :merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :merchant_id, :partner_id
    validates :chargeback_id, numericality: { greater_than: 0, only_integer: true }
    validates :amount, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      stakeholder_id, stakeholder_type = stakeholder_for

      tuples_for_pair("reverse_chargeback_#{stakeholder_type}".to_sym, chargeback_id, stakeholder_id, currency)
    end

    def runtime_check
      require_sufficient_balance!(
        book_id: :chargeback_loss,
        gid: chargeback_id,
        currency:,
        amount:,
        op_label: "reverse_chargeback",
        balance_label: "loss balance",
      )
    end

    def perform(operation_id)
      stakeholder_id, stakeholder_type = stakeholder_for

      EntryPair.public_send(
        "add_reverse_chargeback_#{stakeholder_type}".to_sym,
        chargeback_id,
        stakeholder_id,
        amount,
        currency,
        operation_id:,
      )
    end
  end
end
