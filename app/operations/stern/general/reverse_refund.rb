# frozen_string_literal: true

module Stern
  # Reverses a previously settled refund, returning the credit from the
  # customer's available balance to the funder's available balance (forward
  # direction: `customer_available -> *_available`). Single-pair direct
  # unwind in the same idiom as `ReverseWithdrawal`.
  #
  # Funder identity (merchant vs partner) was consumed at `lock_refund_*`
  # and drained into the fungible `refund_confirmed`, so it is not derivable
  # from `refund_id` alone — the caller must re-supply it.
  #
  # Entries land at gid=funder (uid=refund_id), matching the per-stakeholder
  # attribution of `reverse_withdrawal_*`. `customer_available` is not
  # `non_negative`, so by default the op raises `InsufficientFunds` when
  # `customer_available[customer_id]` would not cover the reversal; pass
  # `allow_overdraft: true` to skip the friendly check (mirrors `LockBalance`).
  class ReverseRefund < BaseOperation
    inputs :merchant_id, :partner_id, :customer_id, :refund_id, :amount, :currency, :allow_overdraft

    validates :merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :merchant_id, :partner_id
    validates :customer_id, numericality: { greater_than: 0, only_integer: true }
    validates :refund_id, numericality: { greater_than: 0, only_integer: true }
    validates :amount, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false
    validates :allow_overdraft, inclusion: { in: [ true, false ] }

    def normalize_inputs
      self.allow_overdraft = false if allow_overdraft.nil?
    end

    def target_tuples
      funder_id, funder_type = funder_for

      tuples_for_pair("reverse_refund_#{funder_type}".to_sym, customer_id, funder_id, currency)
    end

    def runtime_check
      return if allow_overdraft

      require_sufficient_balance!(
        book_id: :customer_available,
        gid: customer_id,
        currency:,
        amount:,
        op_label: "reverse_refund",
        balance_label: "available balance",
      )
    end

    def perform(operation_id)
      funder_id, funder_type = funder_for

      EntryPair.public_send(
        "add_reverse_refund_#{funder_type}".to_sym,
        refund_id,
        funder_id,
        amount,
        currency,
        operation_id:,
      )
    end
  end
end
