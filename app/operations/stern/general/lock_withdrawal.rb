# frozen_string_literal: true

module Stern
  class LockWithdrawal < BaseOperation
    inputs :merchant_id, :partner_id, :customer_id, :amount, :currency, :capped

    validates :merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :customer_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :merchant_id, :customer_id, :partner_id
    validates :amount, presence: true, numericality: { only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false
    validates :capped, inclusion: { in: [ true, false ] }

    def normalize_inputs
      self.capped = true if capped.nil?
    end

    def target_tuples
      stakeholder_id, type = stakeholder
      return [] if stakeholder_id.nil?

      tuples_for_pair("withdraw_lock_withdrawal_#{type}".to_sym, stakeholder_id, stakeholder_id, currency)
    end

    def perform(operation_id)
      stakeholder_id, type = stakeholder

      available_balance = BalanceQuery.new(gid: stakeholder_id, book_id: "#{type}_available".to_sym, currency:, timestamp: Time.current).call
      return if capped && available_balance < amount

      EntryPair.public_send(
        "add_withdraw_lock_withdrawal_#{type}".to_sym,
        stakeholder_id,
        stakeholder_id,
        amount,
        currency,
        operation_id:,
      )
    end

    private

    def stakeholder
      return [ merchant_id, :merchant ] if merchant_id.present?
      return [ customer_id, :customer ] if customer_id.present?
      return [ partner_id, :partner ] if partner_id.present?

      [ nil, nil ]
    end
  end
end
