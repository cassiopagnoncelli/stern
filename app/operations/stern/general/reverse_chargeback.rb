# frozen_string_literal: true

module Stern
  # Reverses a previously confirmed chargeback (issuer overturned the dispute)
  # by recovering the recognized loss to the funder's available balance
  # (forward direction: `chargeback_loss -> *_available`). Single-pair direct
  # unwind in the same idiom as `ReverseWithdrawal`.
  #
  # Funder identity (merchant vs partner) was consumed at `lock_chargeback_*`
  # and drained into the fungible `chargeback_loss`, so it is not derivable
  # from `chargeback_id` alone — the caller must re-supply it.
  #
  # Entries land at gid=funder (uid=chargeback_id), matching the
  # per-stakeholder attribution of `reverse_withdrawal_*`. `chargeback_loss`
  # is not `non_negative` because reversals create offsetting entries at
  # gid=funder rather than draining the original gid=chargeback_id slot;
  # over-reversal protection is the caller's responsibility (idem_key on the
  # dispute event id).
  class ReverseChargeback < BaseOperation
    inputs :merchant_id, :partner_id, :chargeback_id, :amount, :currency

    validates :merchant_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates :partner_id, numericality: { greater_than: 0, only_integer: true }, allow_nil: true
    validates_exactly_one_of :merchant_id, :partner_id
    validates :chargeback_id, numericality: { greater_than: 0, only_integer: true }
    validates :amount, presence: true, numericality: { greater_than: 0, only_integer: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    performs_stakeholder_pair "reverse_chargeback_%{type}", sub_gid: :chargeback_id
  end
end
