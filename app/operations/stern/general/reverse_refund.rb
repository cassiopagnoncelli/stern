# frozen_string_literal: true

module Stern
  # Reverses a previously settled refund, returning the credit from the
  # customer's available balance to the funder's available balance (forward
  # direction: `customer_available -> *_available`). Single-pair direct
  # unwind in the same idiom as `ReverseWithdrawal` — does not retrace
  # through `refund_confirmed` / `refund_locked`.
  #
  # Funder identity (merchant vs partner) was consumed at `lock_refund_*`
  # and drained into the fungible `refund_confirmed`, so it is not derivable
  # from `refund_id` alone — the caller must re-supply it.
  #
  # `customer_available` is not flagged `non_negative`, so by default the op
  # raises `InsufficientFunds` when the customer's slice would overdraw.
  # Pass `allow_overdraft: true` when the host flow has decided the customer
  # may go negative (mirrors `LockBalance`).
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
      stakeholder_id, stakeholder_type = stakeholder_for

      tuples_for_pair("reverse_refund_#{stakeholder_type}".to_sym, customer_id, stakeholder_id, currency)
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
      stakeholder_id, stakeholder_type = stakeholder_for

      EntryPair.public_send(
        "add_reverse_refund_#{stakeholder_type}".to_sym,
        customer_id,
        stakeholder_id,
        amount,
        currency,
        operation_id:,
      )
    end
  end
end
