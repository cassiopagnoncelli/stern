# frozen_string_literal: true

module Stern
  # Pay a merchant boleto.
  #
  # - apply credits
  # - add_boleto_fee
  # - add_boleto_payment
  class PayBoleto < BaseOperation
    include ActiveModel::Validations

    attr_accessor :payment_id, :merchant_id, :amount, :fee

    validates :payment_id, presence: true, numericality: { other_than: 0 }
    validates :merchant_id, presence: true, numericality: { other_than: 0 },
                            unless: -> { validation_context == :undo }
    validates :amount, presence: true, numericality: { other_than: 0 },
                       unless: -> { validation_context == :undo }
    validates :fee, presence: true, numericality: true, unless: -> { validation_context == :undo }

    # Initialize the object, use `call` to perform the operation or `call_undo` to undo it.
    #
    # @param payment_id [Bigint] unique payment id
    # @param merchant_id [Bigint] merchant id
    # @param amount [Bigint] amount in cents
    # @param fee [Bigint] amount in cents
    def initialize(payment_id: nil, merchant_id: nil, amount: nil, fee: nil)
      self.payment_id = payment_id
      self.merchant_id = merchant_id
      self.amount = amount
      self.fee = fee
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      credits = ::Stern.balance(merchant_id, :merchant_credit)
      charged_credits = [fee, credits].min
      charged_fees = fee - charged_credits

      credit_entry_pair_id = apply_credits(charged_credits, merchant_id) if charged_credits.abs.positive?
      if charged_fees.abs.positive?
        EntryPair.add_boleto_fee(payment_id, merchant_id, charged_fees,
                          operation_id:,)
      end
      EntryPair.add_boleto_payment(payment_id, merchant_id, amount, credit_entry_pair_id, operation_id:)
    end

    def perform_undo
      raise ArgumentError if invalid?(:undo)

      credit_entry_pair_id = EntryPair.find_by!(code: ENTRY_PAIRS[:add_boleto_payment], uid: payment_id).credit_entry_pair_id
      EntryPair.remove_credit(credit_entry_pair_id) if credit_entry_pair_id.present?
      EntryPair.remove_boleto_fee(payment_id)
      EntryPair.remove_boleto_payment(payment_id)
    end
  end
end
