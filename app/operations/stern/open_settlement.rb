# frozen_string_literal: true

module Stern
  # Start a merchant settlement.
  #
  # - add_settlement_processing
  class OpenSettlement < BaseOperation
    include ActiveModel::Validations

    UID = 7

    attr_accessor :settlement_id, :merchant_id, :amount

    validates :settlement_id, presence: true, numericality: { other_than: 0 }
    validates :merchant_id, presence: true, numericality: { other_than: 0 },
                            unless: -> { validation_context == :undo }
    validates :amount, presence: true, numericality: { other_than: 0 },
                       unless: -> { validation_context == :undo }

    # Initialize the object, use `call` to perform the operation or `call_undo` to undo it.
    #
    # @param settlement_id [Bigint] unique settlement id
    # @param merchant_id [Bigint] merchant id
    # @param amount [Bigint] amount in cents
    def initialize(settlement_id: nil, merchant_id: nil, amount: nil)
      self.settlement_id = settlement_id
      self.merchant_id = merchant_id
      self.amount = amount
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      Tx.add_settlement_processing(settlement_id, merchant_id, amount, nil, operation_id:)
    end

    def perform_undo
      raise ArgumentError if invalid?(:undo)

      Tx.remove_settlement(settlement_id)
    end
  end
end
