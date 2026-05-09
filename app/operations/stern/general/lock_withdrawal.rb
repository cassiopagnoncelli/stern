# frozen_string_literal: true

module Stern
  class LockWithdrawal < BaseOperation
    inputs :merchant_id, :partner_id, :customer_id, :amount, :currency, :allow_overdraft

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

    performs_stakeholder_pair "lock_withdrawal_%{type}",
      requires_balance: { book: "%{type}_available", label: "available balance", bypass_when: :allow_overdraft }
  end
end
