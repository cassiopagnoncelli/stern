# frozen_string_literal: true

module Stern
  class TransferBalance < BaseOperation
    inputs :from_merchant_id, :from_customer_id, :from_partner_id, :to_merchant_id, :to_customer_id, :to_partner_id, :amount, :currency

    validates :from_merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :from_customer_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :from_partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :from_merchant_id, :from_customer_id, :from_partner_id
    validates :to_merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :to_customer_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :to_partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :to_merchant_id, :to_customer_id, :to_partner_id
    validate do
      errors.add(:base, "cannot transfer to self") if
        (from_merchant_id.present? && from_merchant_id == to_merchant_id) ||
        (from_customer_id.present? && from_customer_id == to_customer_id) ||
        (from_partner_id.present? && from_partner_id == to_partner_id)
    end
    validates :amount, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      from_stakeholder_id, from_stakeholder_type = from_stakeholder
      to_stakeholder_id, to_stakeholder_type = to_stakeholder

      tuples = []
      tuples += tuples_for_pair("#{from_stakeholder_type}_available".to_sym, from_stakeholder_id, from_stakeholder_id, currency)
      tuples += tuples_for_pair("#{to_stakeholder_type}_available".to_sym, to_stakeholder_id, to_stakeholder_id, currency)
      tuples
    end

    def perform(operation_id)
      from_stakeholder_id, from_stakeholder_type = from_stakeholder
      to_stakeholder_id, to_stakeholder_type = to_stakeholder

      balance = available_balance
      if amount.nil?
        amount = balance
      elsif amount > balance
        raise ArgumentError, "amount is larger than available balance"
      end

      EntryPair.public_send(
        "add_#{from_stakeholder_type}_available".to_sym,
        from_merchant_id,
        from_merchant_id,
        -amount,
        currency,
        operation_id:
      )
      EntryPair.public_send(
        "add_#{to_stakeholder_type}_available".to_sym,
        to_merchant_id,
        to_merchant_id,
        -amount,
        currency,
        operation_id:
      )
    end

    private

    def available_balance
      stakeholder_id, stakeholder_type = from_stakeholder

      BalanceQuery.new(
        gid: stakeholder_id,
        book_id: "#{stakeholder_type}_available".to_sym,
        currency:,
        timestamp: Time.current
      ).call
    end

    def from_stakeholder
      return [ from_merchant_id, :merchant ] if from_merchant_id.present?
      return [ from_customer_id, :customer ] if from_customer_id.present?
      return [ from_partner_id, :partner ] if from_partner_id.present?

      [ nil, nil ]
    end

    def to_stakeholder
      return [ to_merchant_id, :merchant ] if to_merchant_id.present?
      return [ to_customer_id, :customer ] if to_customer_id.present?
      return [ to_partner_id, :partner ] if to_partner_id.present?

      [ nil, nil ]
    end
  end
end
