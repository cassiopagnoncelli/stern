# frozen_string_literal: true

module Stern
  # Issues new credit to a stakeholder. Counterparty is the implicit
  # `<stakeholder>_credit_0` sink, representing a grant from outside the
  # stakeholder's own ledger (e.g. promotional credit, goodwill, system top-up).
  #
  # Note: `ApplyCredit` with a negative amount also increases the credit book,
  # but its counterparty is `<stakeholder>_available` — i.e. credit funded by
  # the stakeholder's own balance, not by an external grant. Pick the operation
  # that matches the real-world counterparty; the audit trail depends on it.
  class AddCredit < BaseOperation
    inputs :merchant_id, :customer_id, :partner_id, :amount, :currency

    validates :merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :customer_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :merchant_id, :customer_id, :partner_id
    validates :amount, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      stakeholder_id, stakeholder_type = stakeholder_for

      tuples_for_pair("#{stakeholder_type}_credit".to_sym, stakeholder_id, stakeholder_id, currency)
    end

    def perform(operation_id)
      stakeholder_id, stakeholder_type = stakeholder_for

      EntryPair.public_send(
        "add_#{stakeholder_type}_credit".to_sym,
        stakeholder_id,
        stakeholder_id,
        amount,
        currency,
        operation_id:
      )
    end
  end
end
