# frozen_string_literal: true

module Stern
  # Pay a merchant pix.
  #
  # - apply credits
  # - add_pix_fee
  # - add_pix_payment
  class PayPix < BaseOperation
    include ActiveModel::Validations

    UID = 9

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

      credit_tx_id = apply_credits(charged_credits, merchant_id) if charged_credits.abs.positive?
      if charged_fees.abs.positive?
        Tx.add_pix_fee(payment_id, merchant_id, charged_fees, operation_id:)
      end
      Tx.add_pix_payment(payment_id, merchant_id, amount, credit_tx_id, operation_id:)
    end

    def perform_undo
      raise ArgumentError if invalid?(:undo)

      credit_tx_id = Tx.find_by!(code: TXS[:add_pix_payment], uid: payment_id).credit_tx_id
      Tx.remove_credit(credit_tx_id) if credit_tx_id.present?
      Tx.remove_pix_fee(payment_id)
      Tx.remove_pix_payment(payment_id)
    end
  end
end
