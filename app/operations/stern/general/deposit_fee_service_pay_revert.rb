# frozen_string_literal: true

module Stern
  class DepositFeeServicePayRevert < BaseOperation
    include ActiveModel::Validations

    attr_accessor :deposit_fsp_id, :customer_id, :currency, :fee

    validates :deposit_fsp_id, presence: true, numericality: { other_than: 0 }
    validates :customer_id, presence: true, numericality: { other_than: 0 }
    validates :currency, presence: true, allow_blank: false, allow_nil: false
    validates :fee, presence: true

    UnknownCurrencyError = Class.new(StandardError)

    # Initialize the object, use `call` to perform the operation or `call_undo` to undo it.
    #
    # @param deposit_fsp_id [Bigint] unique deposit id
    # @param customer_id [Bigint] customer id
    # @param currency [Str] curreny code (eg. usd, eur, btc)
    # @param fee [Bigint] fee reverted from customer balance
    def initialize(deposit_fsp_id: nil, customer_id: nil, currency: nil, fee: nil)
      self.deposit_fsp_id = deposit_fsp_id
      self.customer_id = customer_id
      self.currency = currency.strip.downcase.presence
      self.fee = fee
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      raise UnknownCurrencyError unless currency.presence&.in?(%w[usd])

      EntryPair.add_service_deposit_fee_revert_usd(deposit_fsp_id, customer_id, fee, nil, operation_id:) if fee.present?
    end

    def perform_undo
      raise ArgumentError if invalid?(:undo)

      if EntryPair.find_by(code: ENTRY_PAIRS[:add_service_deposit_fee_revert_usd], uid: deposit_fsp_id).present?
        EntryPair.remove_service_deposit_fee_revert_usd(deposit_fsp_id)
      end
    end
  end
end
