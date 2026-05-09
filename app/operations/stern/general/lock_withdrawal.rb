# frozen_string_literal: true

module Stern
  class LockWithdrawal < BaseOperation
    inputs :merchant_id, :partner_id, :customer_id, :amount, :currency, :capped

    validates :merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :customer_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :merchant_id, :customer_id, :partner_id
    validates :amount, presence: true, numericality: { other_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false
    # capped defaults to true via normalize_inputs (runs in the constructor);
    # this inclusion check is for type-guarding non-boolean inputs like "yes",
    # not for enforcing the default.
    validates :capped, inclusion: { in: [ true, false ] }

    def normalize_inputs
      self.capped = true if capped.nil?
    end

    def target_tuples
      stakeholder_id, stakeholder_type = stakeholder_for

      tuples_for_pair("lock_withdrawal_#{stakeholder_type}".to_sym, stakeholder_id, stakeholder_id, currency)
    end

    # A negative `amount` represents an unlock (the inverse pair direction):
    # available is credited and wdw_*_locked is debited. The capped check
    # only applies to forward locks, so we skip it for amount <= 0.
    def runtime_check
      return unless capped && amount.positive?

      stakeholder_id, stakeholder_type = stakeholder_for
      if amount > available_balance(stakeholder_id, stakeholder_type)
        errors.add(:amount, "is larger than available balance")
      end
    end

    def perform(operation_id)
      stakeholder_id, stakeholder_type = stakeholder_for

      EntryPair.public_send(
        "add_lock_withdrawal_#{stakeholder_type}".to_sym,
        stakeholder_id,
        stakeholder_id,
        amount,
        currency,
        operation_id:,
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
