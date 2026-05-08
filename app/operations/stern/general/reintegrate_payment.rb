# frozen_string_literal: true

module Stern
  class ReintegratePayment < BaseOperation
    inputs :merchant_id, :partner_id, :refund_id, :chargeback_id, :amount, :currency

    validates :merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :merchant_id, :partner_id
    validates :refund_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :chargeback_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :refund_id, :chargeback_id
    validates :amount, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      stakeholder_id, stakeholder_type = stakeholder
      target_id, target_type = target

      tuples_for_pair("lock_#{target_type}_#{stakeholder_type}".to_sym, stakeholder_id, target_id, currency)
    end

    def perform(operation_id)
      stakeholder_id, stakeholder_type = stakeholder
      target_id, target_type = target

      EntryPair.public_send(
        "lock_#{target_type}_#{stakeholder_type}",
        stakeholder_id,
        target_id,
        amount,
        currency,
        operation_id:
      )
    end

    private

    def stakeholder
      return [ merchant_id, :merchant ] if merchant_id.present?
      return [ partner_id, :partner ] if partner_id.present?

      [ nil, nil ]
    end

    def target
      return [ refund_id, :refund ] if refund_id.present?
      return [ chargeback_id, :chargeback ] if chargeback_id.present?

      [ nil, nil ]
    end
  end
end
