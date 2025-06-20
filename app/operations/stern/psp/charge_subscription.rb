# frozen_string_literal: true

module Stern
  # Charges a merchant subscription from credits and/or merchant balance.
  #
  # - apply credits
  # - add_subscription
  class ChargeSubscription < BaseOperation
    include ActiveModel::Validations

    attr_accessor :subs_charge_id, :merchant_id, :amount

    validates :subs_charge_id, presence: true, numericality: { other_than: 0 }
    validates :merchant_id, presence: true, numericality: { other_than: 0 },
                            unless: -> { validation_context == :undo }
    validates :amount, presence: true, numericality: { other_than: 0 },
                       unless: -> { validation_context == :undo }

    # Initialize the object, use `call` to perform the operation or `call_undo` to undo it.
    #
    # @param subs_charge_id [Bigint] unique subscription charge id
    # @param merchant_id [Bigint] merchant id
    # @param amount [Bigint] amount in cents
    def initialize(subs_charge_id: nil, merchant_id: nil, amount: nil)
      self.subs_charge_id = subs_charge_id
      self.merchant_id = merchant_id
      self.amount = amount
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      credits = ::Stern.balance(merchant_id, :merchant_credit)
      charged_credits = [amount, credits].min
      charged_subs = amount - charged_credits

      credit_entry_pair_id = apply_credits(charged_credits, merchant_id)
      EntryPair.add_subscription(subs_charge_id, merchant_id, charged_subs, credit_entry_pair_id, operation_id:)
    end

    def perform_undo
      raise ArgumentError if invalid?(:undo)

      credit_entry_pair_id = EntryPair.find_by!(code: ENTRY_PAIRS[:add_subscription], uid: subs_charge_id).credit_entry_pair_id
      EntryPair.remove_credit(credit_entry_pair_id) if credit_entry_pair_id.present?
      EntryPair.remove_subscription(subs_charge_id)
    end
  end
end
