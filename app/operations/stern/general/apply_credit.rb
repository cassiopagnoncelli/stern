# frozen_string_literal: true

module Stern
  # Redeems credit into the stakeholder's available balance
  # (`<stakeholder>_credit` → `<stakeholder>_available`). A negative amount
  # reverses the move and increases the credit book against the available
  # balance — semantically "add credit funded by the stakeholder's own cash."
  #
  # That overlaps with `AddCredit` in effect on the credit book, but the
  # counterparties differ: `AddCredit` debits the external `_credit_0` sink
  # (grant from outside the ledger), while negative `ApplyCredit` debits
  # `_available` (move from the stakeholder's own funds). Choose by which
  # counterparty reflects reality.
  class ApplyCredit < BaseOperation
    inputs :merchant_id, :customer_id, :partner_id, :amount, :currency

    validates :merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :customer_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :merchant_id, :customer_id, :partner_id
    validates :amount, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      stakeholder_id, stakeholder_type = stakeholder_for

      tuples_for_pair("apply_#{stakeholder_type}_credit".to_sym, stakeholder_id, stakeholder_id, currency)
    end

    def perform(operation_id)
      stakeholder_id, stakeholder_type = stakeholder_for

      EntryPair.public_send(
        "add_apply_#{stakeholder_type}_credit".to_sym,
        stakeholder_id,
        stakeholder_id,
        amount,
        currency,
        operation_id:
      )
    end
  end
end
