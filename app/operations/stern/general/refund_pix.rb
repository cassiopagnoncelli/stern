# frozen_string_literal: true

module Stern
  class RefundPix < BaseOperation
    include ActiveModel::Validations

    inputs :refund_id, :payment_id, :merchant_id, :customer_id, :amount, :currency, :fee

    validates :refund_id, presence: true, numericality: { other_than: 0 }
    validates :payment_id, presence: true, numericality: { other_than: 0 }
    validates :merchant_id, presence: true, numericality: { greater_than: 0 }
    validates :customer_id, numericality: { greater_than: 0, only_integer: true, allow_nil: true }
    validates :amount, presence: true, numericality: { greater_than: 0 }
    validates :fee, numericality: { greater_than_or_equal_to: 0, allow_nil: true }
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      tuples = tuples_for_pair(:pp_refund_merchant_pix, payment_id, currency)
      tuples += tuples_for_pair(:pp_refund_fee_merchant_pix, payment_id, currency) if fee&.positive?
      tuples += customer_id ? tuples_for_pair(:refund_identified_customer, customer_id, currency)
                            : tuples_for_pair(:refund_unidentified_customer, merchant_id, currency)
      tuples
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      EntryPair.add_pp_refund_merchant_pix(refund_id, payment_id, amount, currency, operation_id:)
      EntryPair.add_pp_refund_fee_merchant_pix(refund_id, payment_id, fee, currency, operation_id:) if fee&.positive?
      if customer_id
        EntryPair.add_refund_identified_customer(refund_id, customer_id, amount, currency, operation_id:)
      else
        EntryPair.add_refund_unidentified_customer(refund_id, merchant_id, amount, currency, operation_id:)
      end
    end
  end
end
