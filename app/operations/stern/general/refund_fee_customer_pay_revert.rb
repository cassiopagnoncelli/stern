# frozen_string_literal: true

module Stern
  # Revert of refund fee paid by the customer.
  class RefundFeeCustomerPayRevert < BaseOperation
    include ActiveModel::Validations

    attr_accessor :refund_fcp_id, :customer_id, :currency, :fee

    validates :refund_fcp_id, presence: true, numericality: { other_than: 0 }
    validates :customer_id, presence: true, numericality: { other_than: 0 }
    validates :currency, presence: true, allow_blank: false, allow_nil: false
    validates :fee, presence: false

    UnknownCurrencyError = Class.new(StandardError)

    # Initialize the object, use `call` to perform the operation or `call_undo` to undo it.
    #
    # @param refund_fcp_id [Bigint] unique refund fee customer pay id
    # @param customer_id [Bigint] customer id
    # @param currency [Str] curreny code (eg. usd, eur, btc)
    # @param fee [Bigint] fee requested from customer balance
    def initialize(refund_fcp_id: nil, customer_id: nil, currency: nil, fee: nil)
      self.refund_fcp_id = refund_fcp_id
      self.customer_id = customer_id
      self.currency = currency.strip.downcase.presence
      self.fee = fee
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      raise UnknownCurrencyError unless currency.presence&.in?(%w[usd])

      EntryPair.add_refund_fee_customer_pay_revert_usd(refund_fcp_id, customer_id, fee, nil, operation_id:) if fee.present?
    end

    def perform_undo
      raise ArgumentError if invalid?(:undo)

      if EntryPair.find_by(code: ENTRY_PAIRS[:add_refund_fee_customer_pay_revert_usd], uid: refund_fcp_id).present?
        EntryPair.remove_refund_fee_customer_pay_revert_usd(refund_fcp_id)
      end
    end
  end
end
