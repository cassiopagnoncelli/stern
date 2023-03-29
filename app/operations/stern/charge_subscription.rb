module Stern
  class ChargeSubscription < BaseOperation
    attr_accessor :subs_charge_id, :merchant_id, :amount, :timestamp

    def initialize(subs_charge_id: nil, merchant_id: nil, amount: nil, timestamp: DateTime.current)
      @subs_charge_id = subs_charge_id
      @merchant_id = merchant_id
      @amount = amount
      @timestamp = timestamp
    end

    def perform
      raise ParameterMissingError unless subs_charge_id.present? && subs_charge_id.is_a?(Numeric)
      raise ParameterMissingError unless merchant_id.present? && merchant_id.is_a?(Numeric)
      raise ParameterMissingError unless amount.present? && amount.is_a?(Numeric)
      raise ParameterMissingError unless timestamp.present? && timestamp.is_a?(DateTime)
      raise AmountShouldNotBeZeroError if amount.zero?

      credits = ::Stern.balance(merchant_id, :merchant_credit)
      charged_credits = [amount, credits].min
      charged_subs = amount - charged_credits

      ts0 = timestamp
      ts1 = timestamp + STERN_TIMESTAMP_DELTA

      credit_tx_id = apply_credits(charged_credits, merchant_id, ts0)
      Tx.add_subscription(subs_charge_id, merchant_id, charged_subs, ts1, credit_tx_id, cascade: false)
    end

    def undo
      raise ParameterMissingError unless subs_charge_id.present? && subs_charge_id.is_a?(Numeric)

      credit_tx_id = Tx.find_by!(code: Tx.codes[:add_subscription], uid: subs_charge_id).credit_tx_id

      Tx.remove_credit(credit_tx_id) if credit_tx_id.present?
      Tx.remove_subscription(subs_charge_id)
    end
  end
end
