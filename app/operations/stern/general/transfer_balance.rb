# frozen_string_literal: true

module Stern
  class TransferBalance < BaseOperation
    inputs :from_merchant_id, :from_customer_id, :from_partner_id, :to_merchant_id, :to_customer_id, :to_partner_id, :amount, :currency, :allow_overdraft

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
    validates :allow_overdraft, inclusion: { in: [ true, false ] }
    # The drain semantics (`amount: nil` → use the sender's full available
    # balance) depend on a balance read; with `allow_overdraft: true` there's
    # nothing meaningful to drain, so the combination is rejected upfront.
    validate do
      errors.add(:amount, "must be set when allow_overdraft is true") if allow_overdraft && amount.nil?
    end

    def normalize_inputs
      self.allow_overdraft = false if allow_overdraft.nil?
    end

    def target_tuples
      from_id, from_type = stakeholder_for("from_")
      to_id, to_type = stakeholder_for("to_")

      tuples = []
      tuples += tuples_for_pair("#{from_type}_available".to_sym, from_id, from_id, currency)
      tuples += tuples_for_pair("#{to_type}_available".to_sym, to_id, to_id, currency)
      tuples
    end

    def runtime_check
      from_id, from_type = stakeholder_for("from_")
      balance = available_balance(from_id, from_type)

      if allow_overdraft
        return
      end

      if balance <= 0
        raise ::Stern::InsufficientFunds,
          "transfer_balance has no available balance to transfer (balance #{balance})"
      end

      if amount.nil?
        self.amount = balance
      elsif amount > balance
        raise ::Stern::InsufficientFunds,
          "transfer_balance amount #{amount} exceeds available balance #{balance}"
      end
    end

    def perform(operation_id)
      from_id, from_type = stakeholder_for("from_")
      to_id, to_type = stakeholder_for("to_")

      EntryPair.public_send(
        "add_#{from_type}_available".to_sym,
        from_id,
        from_id,
        -amount,
        currency,
        operation_id:
      )
      EntryPair.public_send(
        "add_#{to_type}_available".to_sym,
        to_id,
        to_id,
        amount,
        currency,
        operation_id:
      )
    end

    private

    def available_balance(stakeholder_id, stakeholder_type)
      BalanceQuery.new(
        gid: stakeholder_id,
        book_id: "#{stakeholder_type}_available".to_sym,
        currency:,
        timestamp: Time.current
      ).call
    end
  end
end
