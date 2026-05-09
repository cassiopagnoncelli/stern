# frozen_string_literal: true

module Stern
  class ChargeChargebackFee < BaseOperation
    inputs :merchant_id, :partner_id, :amount, :currency

    validates :merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :merchant_id, :partner_id
    validates :amount, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      stakeholder_id, stakeholder_type = stakeholder

      tuples_for_pair("apply_#{stakeholder_type}_credit".to_sym, stakeholder_id, stakeholder_id, currency)
    end

    def perform(operation_id)
      stakeholder_id, stakeholder_type = stakeholder

      apply_available_credit(stakeholder_id, stakeholder_type, operation_id)

      EntryPair.public_send(
        "add_charge_chargeback_fee_#{stakeholder_type}".to_sym,
        stakeholder_id,
        stakeholder_id,
        amount,
        currency,
        operation_id:,
      )
    end

    private

    # Draws from the stakeholder's *_credit book up to the fee amount and moves
    # it into *_available before the fee is charged in full. The full `amount`
    # is then debited from *_available, so the stakeholder's net out-of-pocket
    # is `amount - credit_used`. No-op for non-positive amounts.
    def apply_available_credit(stakeholder_id, type, operation_id)
      return unless amount.positive?

      credit_balance = ::Stern.balance(stakeholder_id, "#{type}_credit".to_sym, currency)
      credit_to_apply = [ credit_balance, amount ].min
      return unless credit_to_apply.positive?

      EntryPair.public_send(
        "add_apply_#{type}_credit".to_sym,
        stakeholder_id, stakeholder_id, credit_to_apply, currency, operation_id:,
      )
    end

    def stakeholder
      return [ merchant_id, :merchant ] if merchant_id.present?
      return [ partner_id, :partner ] if partner_id.present?

      [ nil, nil ]
    end
  end
end
