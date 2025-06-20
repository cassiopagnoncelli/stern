# frozen_string_literal: true

module Stern
  class DepositFeeCustomerPay < BaseOperation
    include ActiveModel::Validations

    attr_accessor :deposit_fcp_id, :customer_id, :currency, :fee

    validates :deposit_fcp_id, presence: true, numericality: { other_than: 0 }
    validates :customer_id, presence: true, numericality: { other_than: 0 }
    validates :currency, presence: true, allow_blank: false, allow_nil: false
    validates :fee, presence: true

    UnknownCurrencyError = Class.new(StandardError)

    # Initialize the object, use `call` to perform the operation or `call_undo` to undo it.
    #
    # @param deposit_fcp_id [Bigint] unique deposit id
    # @param customer_id [Bigint] customer id
    # @param currency [Str] curreny code (eg. usd, eur, btc)
    # @param fee [Bigint] fee paid by customer
    def initialize(deposit_fcp_id: nil, customer_id: nil, currency: nil, fee: nil)
      self.deposit_fcp_id = deposit_fcp_id
      self.customer_id = customer_id
      self.currency = currency.strip.downcase.presence
      self.fee = fee
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      raise UnknownCurrencyError unless currency.presence&.in?(%w[usd])

      EntryPair.add_customer_deposit_fee_usd(deposit_fcp_id, customer_id, fee, nil, operation_id:) if fee.present?
    end

    def perform_undo
      raise ArgumentError if invalid?(:undo)

      if EntryPair.find_by(code: ENTRY_PAIRS[:add_customer_deposit_fee_usd], uid: deposit_fcp_id).present?
        EntryPair.remove_customer_deposit_fee_usd(deposit_fcp_id)
      end
    end
  end
end
