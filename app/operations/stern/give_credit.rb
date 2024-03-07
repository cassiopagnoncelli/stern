# frozen_string_literal: true

module Stern
  # Give away merchant credit.
  #
  # - add_credit
  class GiveCredit < BaseOperation
    include ActiveModel::Validations

    UID = 6

    attr_accessor :uid, :merchant_id, :amount

    validates :uid, presence: true, numericality: { other_than: 0 }
    validates :merchant_id, presence: true, numericality: { other_than: 0 },
                            unless: -> { validation_context == :undo }
    validates :amount, presence: true, numericality: { other_than: 0 },
                       unless: -> { validation_context == :undo }

    # Initialize the object, use `call` to perform the operation or `call_undo` to undo it.
    #
    # @param uid [Bigint] unique id
    # @param merchant_id [Bigint] merchant id
    # @param amount [Bigint] amount in cents
    def initialize(uid: nil, merchant_id: nil, amount: nil)
      self.uid = uid
      self.merchant_id = merchant_id
      self.amount = amount
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?

      Tx.add_credit(uid, merchant_id, amount, operation_id:)
    end

    def perform_undo
      raise ArgumentError if invalid?(:undo)

      tx = Tx.find_by!(code: TXS[:add_credit], uid:)
      Tx.remove_credit(tx.id)
    end
  end
end
