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
  # Each leg lands at its natural gid: `customer_available` is debited at
  # `gid=customer_id`, the funder's available is credited at `gid=funder_id`.
  # The `EntryPair`'s `uid` is `refund_id` so the entry pair is grouped by
  # the cause (the refund being reversed). `customer_available` is not
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

    performs_stakeholder_pair "reverse_refund_%{type}",
      using: :funder_for,
      sub_gid: :customer_id,
      add_gid: :resolved,
      entry_uid: :refund_id,
      requires_balance: { book: :customer_available, label: "available balance", bypass_when: :allow_overdraft }
  end
end
