# frozen_string_literal: true

module Stern
  class LockBalance < BaseOperation
    inputs :merchant_id, :customer_id, :partner_id, :amount, :currency, :allow_overdraft

    validates :merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :customer_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :merchant_id, :customer_id, :partner_id
    validates :amount, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false
    # allow_overdraft defaults to false via normalize_inputs (runs in the
    # constructor); this inclusion check is for type-guarding non-boolean
    # inputs like "yes", not for enforcing the default.
    validates :allow_overdraft, inclusion: { in: [ true, false ] }

    def normalize_inputs
      self.allow_overdraft = false if allow_overdraft.nil?
    end

    def target_tuples
      stakeholder_id, stakeholder_type = stakeholder_for

      tuples_for_pair("lock_#{stakeholder_type}_balance".to_sym, stakeholder_id, stakeholder_id, currency)
    end

    def runtime_check
      return if allow_overdraft

      stakeholder_id, stakeholder_type = stakeholder_for

      require_sufficient_balance!(
        book_id: "#{stakeholder_type}_available".to_sym,
        gid: stakeholder_id,
        currency:,
        amount:,
        op_label: "lock_balance",
        balance_label: "available balance",
      )
    end

    def perform(operation_id)
      stakeholder_id, stakeholder_type = stakeholder_for

      EntryPair.public_send(
        "add_lock_#{stakeholder_type}_balance".to_sym,
        stakeholder_id,
        stakeholder_id,
        amount,
        currency,
        operation_id:
      )
    end
  end
end
