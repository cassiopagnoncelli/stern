# frozen_string_literal: true

module Stern
  # Charges a payment-method fee against a stakeholder's `*_available`,
  # optionally drawing from `*_credit` first to reduce out-of-pocket.
  #
  # A negative `amount` reverses a previously-charged fee — the same entry
  # pair is emitted with flipped signs. Reverse-refund / reverse-chargeback
  # callers rely on this idiom because `ReverseRefund` / `ReverseChargeback`
  # only unwind the underlying fund movement, not the fee. Credit
  # application is intentionally skipped on the reversal path: the credit
  # redemption from the original charge is its own movement and is not
  # undone here.
  class ChargePaymentFee < BaseOperation
    PAYMENT_METHODS = %w[bank_transfer credit_card debit_card wallet pix].freeze

    inputs :merchant_id, :customer_id, :partner_id, :payment_id, :payment_method, :amount, :currency

    validates :merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :customer_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :merchant_id, :customer_id, :partner_id
    validates :payment_id, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :payment_method, presence: true, inclusion: { in: PAYMENT_METHODS }
    validates :amount, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      stakeholder_id, stakeholder_type = stakeholder_for

      tuples = []
      tuples += tuples_for_pair("charge_#{payment_method}_fee_#{stakeholder_type}".to_sym, stakeholder_id, payment_id, currency)
      tuples += tuples_for_pair("apply_#{stakeholder_type}_credit".to_sym, stakeholder_id, stakeholder_id, currency)
      tuples
    end

    def perform(operation_id)
      stakeholder_id, stakeholder_type = stakeholder_for

      apply_available_credit(stakeholder_id, stakeholder_type, operation_id)

      EntryPair.public_send(
        "add_charge_#{payment_method}_fee_#{stakeholder_type}".to_sym,
        stakeholder_id,
        payment_id,
        amount,
        currency,
        operation_id:,
      )
    end

    private

    # Draws from the stakeholder's *_credit book up to the fee amount and moves
    # it into *_available before the fee is charged in full. The full `amount`
    # is then debited from *_available, so the stakeholder's net out-of-pocket
    # is `amount - credit_used`. Skipped on the reversal path (negative
    # `amount`): the credit redemption from the original charge is its own
    # movement and is not undone here.
    def apply_available_credit(stakeholder_id, stakeholder_type, operation_id)
      return unless amount.positive?

      credit_balance = ::Stern.balance(stakeholder_id, "#{stakeholder_type}_credit".to_sym, currency)
      credit_to_apply = [ credit_balance, amount ].min
      return unless credit_to_apply.positive?

      EntryPair.public_send(
        "add_apply_#{stakeholder_type}_credit".to_sym,
        stakeholder_id, stakeholder_id, credit_to_apply, currency, operation_id:,
      )
    end
  end
end
