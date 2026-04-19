# frozen_string_literal: true

module Stern
  # Revert of chargeback fee paid by the service.
  class ChargebackFeeServicePayRevert < BaseOperation
    include ActiveModel::Validations

    attr_accessor :chargeback_fsp_id, :customer_id, :currency, :fee

    validates :chargeback_fsp_id, presence: true, numericality: { other_than: 0 }
    validates :customer_id, presence: true, numericality: { other_than: 0 }
    validates :currency, presence: true, allow_blank: false, allow_nil: false
    validates :fee, presence: false

    UnknownCurrencyError = Class.new(StandardError)

    # Initialize the object, use `call` to perform the operation or `call_undo` to undo it.
    #
    # @param chargeback_fsp_id [Bigint] unique chargeback fee service pay id
    # @param customer_id [Bigint] customer id
    # @param currency [Str] curreny code (eg. usd, eur, btc)
    # @param fee [Bigint] fee requested from customer balance
    def initialize(chargeback_fsp_id: nil, customer_id: nil, currency: nil, fee: nil)
      self.chargeback_fsp_id = chargeback_fsp_id
      self.customer_id = customer_id
      self.currency = currency.strip.downcase.presence
      self.fee = fee
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      raise UnknownCurrencyError unless currency.presence&.in?(%w[usd])

      EntryPair.add_chargeback_fee_service_pay_revert_usd(chargeback_fsp_id, customer_id, fee, nil, operation_id:) if fee.present?
    end

    def perform_undo
      raise ArgumentError if invalid?(:undo)

      if EntryPair.find_by(code: ENTRY_PAIRS[:add_chargeback_fee_service_pay_revert_usd], uid: chargeback_fsp_id).present?
        EntryPair.remove_chargeback_fee_service_pay_revert_usd(chargeback_fsp_id)
      end
    end
  end
end
