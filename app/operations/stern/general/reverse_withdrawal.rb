# frozen_string_literal: true

module Stern
  # Reverses a previously confirmed withdrawal back to the stakeholder's
  # available balance (forward direction: `wdw_*_confirmed → *_available`).
  # Used for post-settlement rejects (e.g. bank-side bounce) where the
  # withdrawal had already cleared `ConfirmWithdrawal`. For pre-settlement
  # cancellation use `CancelWithdrawal`.
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
      confirmed = confirmed_balance(stakeholder_id, stakeholder_type)
      return if amount <= confirmed

      raise ::Stern::InsufficientFunds,
        "reverse_withdrawal amount #{amount} exceeds confirmed balance #{confirmed}"
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

    private

    def confirmed_balance(stakeholder_id, stakeholder_type)
      BalanceQuery.new(
        gid: stakeholder_id,
        book_id: "wdw_#{stakeholder_type}_confirmed".to_sym,
        currency:,
        timestamp: Time.current
      ).call
    end
  end
end
