# frozen_string_literal: true

module Stern
  # Releases a previously withheld balance back to the stakeholder's available
  # book. Inverse of `WithholdBalance` (forward direction:
  # `*_withheld -> *_available`).
  #
  # Like `*_locked`, `*_withheld` has no `confirmed` companion stage, so a
  # single inverse pair suffices — there is no `Reverse*` counterpart. The
  # DB-level `non_negative` backstop on `*_withheld` translates an over-debit
  # into `BalanceNonNegativeViolation`; the friendly `runtime_check` below
  # raises the parent `Stern::InsufficientFunds` so callers can rescue both
  # layers uniformly.
  class ReleaseWithheldBalance < BaseOperation
    inputs :merchant_id, :customer_id, :partner_id, :amount, :currency

    validates :merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :customer_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :merchant_id, :customer_id, :partner_id
    validates :amount, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      stakeholder_id, stakeholder_type = stakeholder_for

      tuples_for_pair("release_withheld_#{stakeholder_type}_balance".to_sym, stakeholder_id, stakeholder_id, currency)
    end

    def runtime_check
      stakeholder_id, stakeholder_type = stakeholder_for

      require_sufficient_balance!(
        book_id: "#{stakeholder_type}_withheld".to_sym,
        gid: stakeholder_id,
        currency:,
        amount:,
        op_label: "release_withheld_balance",
        balance_label: "withheld balance",
      )
    end

    def perform(operation_id)
      stakeholder_id, stakeholder_type = stakeholder_for

      EntryPair.public_send(
        "add_release_withheld_#{stakeholder_type}_balance".to_sym,
        stakeholder_id,
        stakeholder_id,
        amount,
        currency,
        operation_id:,
      )
    end
  end
end
