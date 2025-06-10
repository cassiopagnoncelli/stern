# frozen_string_literal: true

module Stern
  # Charge merchant the settlement amount.
  #
  # - apply_credits
  # - add_settlement_fee
  # - add_settlement
  class ChargeSettlement < BaseOperation
    include ActiveModel::Validations

    attr_accessor :settlement_id, :merchant_id, :amount, :fee

    validates :settlement_id, presence: true, numericality: { other_than: 0 }
    validates :merchant_id, presence: true, numericality: { other_than: 0 },
                            unless: -> { validation_context == :undo }
    validates :amount, presence: true, numericality: { other_than: 0 },
                       unless: -> { validation_context == :undo }
    validates :fee, presence: true, numericality: true, unless: -> { validation_context == :undo }

    # Initialize the object, use `call` to perform the operation or `call_undo` to undo it.
    #
    # @param settlement_id [Bigint] unique settlement id
    # @param merchant_id [Bigint] merchant id
    # @param amount [Bigint] amount in cents
    # @param fee [Bigint] amount in cents
    def initialize(settlement_id: nil, merchant_id: nil, amount: nil, fee: nil)
      self.settlement_id = settlement_id
      self.merchant_id = merchant_id
      self.amount = amount
      self.fee = fee
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      credits = ::Stern.balance(merchant_id, :merchant_credit)
      charged_credits = [fee, credits].min
      charged_fees = fee - charged_credits

      credit_entry_pair_id = apply_credits(charged_credits, merchant_id)
      EntryPair.add_settlement_fee(settlement_id, merchant_id, charged_fees, operation_id:)
      EntryPair.add_settlement(settlement_id, merchant_id, amount, credit_entry_pair_id, operation_id:)
    end

    def perform_undo
      raise ArgumentError if invalid?(:undo)

      credit_entry_pair_id = EntryPair.find_by!(code: ENTRY_PAIRS[:add_settlement], uid: settlement_id).credit_entry_pair_id
      EntryPair.remove_credit(credit_entry_pair_id) if credit_entry_pair_id.present?
      EntryPair.remove_settlement_fee(settlement_id)
      EntryPair.remove_settlement(settlement_id)
    end
  end
end
