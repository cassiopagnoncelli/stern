# frozen_string_literal: true

module Stern
  # Operations form the interface on top of transactions building blocks.
  #
  # Note. End-user *shouldn't* use transactions directly, but rather operations.
  #
  class Operation < ApplicationRecord
    enum name: %i[
      give_balance revert_give_balance
      give_credit revert_give_credit
      pay_settlement revert_pay_settlement
      charge_subscription revert_charge_subscription
      pay_boleto revert_pay_boleto
      pay_boleto_fee boleto_pay_bolet_fee
    ]

    def self.register(operation, *parameters, timestamp: DateTime.current, cascade: false)
      raise OperationDoesNotExist unless operation.to_s.in?(names)
      raise CascadeShouldBeBoolean unless cascade.in?([true, false])
      raise AtomicShouldBeBoolean unless atomic.in?([true, false])
      raise TimestampShouldBeDateTime unless timestamp.is_a?(Time)

      blk = lambda do
        params = parameters + [timestamp, cascade]
        ::Stern::Operation.public_send(operation.to_sym, *params)
      end

      ApplicationRecord.transaction { blk.call }
    end

    def self.new_credit_tx_id(remaining_tries = 100)
      raise CreditTxIdSeqInvalid unless remaining_tries.positive?

      seq = ::Stern::Tx.generate_tx_credit_id

      already_present = Tx.find_by(code: Tx.codes['add_credit'], uid: seq).present?
      already_present ? new_credit_tx_id(remaining_tries - 1) : seq
    end

    def self.apply_credits(charged_credits, merchant_id, ts0)
      return nil unless charged_credits.present? && charged_credits.abs > 0

      credit_tx_id = new_credit_tx_id
      Tx.add_credit(credit_tx_id, merchant_id, -charged_credits, ts0)
      credit_tx_id
    end

    def self.give_balance(uid, merchant_id, amount, timestamp, cascade)
      raise AmountShouldNotBeZero if amount.zero?

      Tx.add_balance(uid, merchant_id, amount, timestamp, cascade: cascade)
    end

    def self.revert_give_balance(uid, _timestamp, _cascade)
      tx = Tx.find_by!(code: Tx.codes[:add_balance], uid: uid)
      Tx.remove_balance(tx.id)
    end

    def self.give_credit(uid, merchant_id, amount, timestamp, cascade)
      raise AmountShouldNotBeZero if amount.zero?

      Tx.add_credit(uid, merchant_id, amount, timestamp, cascade: cascade)
    end

    def self.revert_give_credit(uid, _timestamp, _cascade)
      tx = Tx.find_by!(code: Tx.codes[:add_credit], uid: uid)
      Tx.remove_credit(tx.id)
    end

    def self.pay_settlement(settlement_id, merchant_id, amount, fee, timestamp, cascade)
      raise AmountShouldNotBeZero if amount.zero?

      credits = Stern.balance(merchant_id, :merchant_credit)
      charged_credits = [fee, credits].min
      charged_fees = fee - charged_credits

      ts0 = timestamp
      ts1 = timestamp + STERN_TIMESTAMP_DELTA
      ts2 = timestamp + 2 * STERN_TIMESTAMP_DELTA

      credit_tx_id = apply_credits(charged_credits, merchant_id, ts0)
      Tx.add_settlement_fee(settlement_id, merchant_id, charged_fees, ts1, nil, cascade: cascade)
      Tx.add_settlement(settlement_id, merchant_id, amount, ts2, credit_tx_id, cascade: cascade)
    end

    def self.revert_pay_settlement(settlement_id, _timestamp, _cascade)
      credit_tx_id = Tx.find_by!(code: Tx.codes[:add_settlement], uid: settlement_id).credit_tx_id
      Tx.remove_credit(credit_tx_id) if credit_tx_id.present?
      Tx.remove_settlement_fee(settlement_id)
      Tx.remove_settlement(settlement_id)
    end

    def self.charge_subscription(subs_charge_id, merchant_id, amount, timestamp, cascade)
      raise AmountShouldNotBeZero if amount.zero?

      credits = Stern.balance(merchant_id, :merchant_credit)
      charged_credits = [amount, credits].min
      charged_subs = amount - charged_credits

      ts0 = timestamp
      ts1 = timestamp + STERN_TIMESTAMP_DELTA

      credit_tx_id = apply_credits(charged_credits, merchant_id, ts0)
      Tx.add_subscription(subs_charge_id, merchant_id, charged_subs, ts1, credit_tx_id, cascade: cascade)
    end

    def self.revert_charge_subscription(subs_charge_id, _timestamp, _cascade)
      credit_tx_id = Tx.find_by!(code: Tx.codes[:add_subscription], uid: subs_charge_id).credit_tx_id
      Tx.remove_credit(credit_tx_id) if credit_tx_id.present?
      Tx.remove_subscription(subs_charge_id)
    end

    def self.pay_boleto(payment_id, merchant_id, amount, fee, timestamp, cascade)
      raise AmountShouldNotBeZero if amount.zero?

      credits = Stern.balance(merchant_id, :merchant_credit)
      charged_credits = [fee, credits].min
      charged_fees = fee - charged_credits

      ts0 = timestamp
      ts1 = timestamp + STERN_TIMESTAMP_DELTA
      ts2 = timestamp + 2 * STERN_TIMESTAMP_DELTA

      credit_tx_id = apply_credits(charged_credits, merchant_id, ts0)
      Tx.add_boleto_fee(payment_id, merchant_id, charged_fees, ts1, cascade: cascade)
      Tx.add_boleto_payment(payment_id, merchant_id, amount, ts2, credit_tx_id, cascade: cascade)
    end

    def self.revert_pay_boleto(payment_id, _timestamp, _cascade)
      credit_tx_id = Tx.find_by!(code: Tx.codes[:add_boleto_payment], uid: payment_id).credit_tx_id
      Tx.remove_credit(credit_tx_id) if credit_tx_id.present?
      Tx.remove_boleto_fee(payment_id)
      Tx.remove_boleto_payment(payment_id)
    end

    def self.pay_boleto_fee(payment_id, merchant_id, fee, timestamp, cascade)
      raise AmountShouldNotBeZero unless fee.abs > 0

      credits = Stern.balance(merchant_id, :merchant_credit)
      charged_credits = [fee, credits].min
      charged_fees = fee - charged_credits

      credit_tx_id = apply_credits(charged_credits, merchant_id, ts0)
      Tx.add_boleto_fee(payment_id, merchant_id, charged_fees, timestamp, credit_tx_id, cascade: cascade)
    end

    def self.revert_pay_boleto_fee(payment_id, _timestamp, _cascade)
      credit_tx_id = Tx.find_by!(code: Tx.codes[:add_boleto_fee], uid: payment_id).credit_tx_id
      Tx.remove_credit(credit_tx_id) if credit_tx_id.present?
      Tx.remove_boleto_fee(payment_id)
    end
  end
end
