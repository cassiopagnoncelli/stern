# frozen_string_literal: true

module Stern
  class SplitPayment < BaseOperation
    inputs :payment_id, :merchant_id, :partner_id, :amount, :currency

    validates :merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :merchant_id, :partner_id
    validates :payment_id, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :amount, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false
    
    def target_tuples
      stakeholder_id, stakeholder_type = stakeholder_for

      tuples_for_pair("split_payment_#{stakeholder_type}".to_sym, payment_id, stakeholder_id, currency)
    end

    def perform(operation_id)
      stakeholder_id, stakeholder_type = stakeholder_for

      EntryPair.public_send(
        "add_split_payment_#{stakeholder_type}".to_sym,
        payment_id,
        stakeholder_id,
        amount,
        currency,
        operation_id:
      )
    end
  end
end
