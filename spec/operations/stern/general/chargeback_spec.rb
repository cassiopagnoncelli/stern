require "rails_helper"

module Stern
  RSpec.describe Chargeback, type: :model do
    let(:merchant_id) { 1101 }
    let(:chargeback_id) { 6262 }

    def valid_inputs(**overrides)
      {
        chargeback_id:,
        amount: 500,
        currency: "BRL"
      }.merge(overrides)
    end

    # Chargeback's prerequisite — `chargeback_locked` is non_negative, so
    # confirm_chargeback can only run if a prior ReintegratePayment locked
    # at least `amount`.
    def lock_chargeback(amount: 500)
      ReintegratePayment.new(merchant_id:, chargeback_id:, amount:, currency: "BRL").call
    end

    describe "validations" do
      it "is valid with complete inputs" do
        expect(described_class.new(**valid_inputs)).to be_valid
      end

      it "rejects a missing chargeback_id" do
        expect(described_class.new(**valid_inputs(chargeback_id: nil))).not_to be_valid
      end

      it "rejects a zero amount" do
        expect(described_class.new(**valid_inputs(amount: 0))).not_to be_valid
      end

      it "treats an unknown currency as invalid" do
        expect(described_class.new(**valid_inputs(currency: "ZZZ"))).not_to be_valid
      end
    end

    describe "#target_tuples" do
      it "locks confirm_chargeback's two sides at chargeback_id" do
        op = described_class.new(**valid_inputs)
        expect(op.target_tuples).to eq([
          [ "chargeback_locked", chargeback_id, "BRL" ],
          [ "chargeback_loss",   chargeback_id, "BRL" ]
        ])
      end
    end

    describe "#call" do
      before { Repair.clear }

      it "drains chargeback_locked at chargeback_id and recognizes loss" do
        lock_chargeback(amount: 500)

        described_class.new(**valid_inputs).call

        expect(::Stern.balance(chargeback_id, :chargeback_locked, :BRL)).to eq(0)
        expect(::Stern.balance(chargeback_id, :chargeback_loss, :BRL)).to eq(500)
      end

      it "writes the confirm_chargeback entry pair" do
        lock_chargeback(amount: 500)

        described_class.new(**valid_inputs).call
        expect(EntryPair.last).to have_attributes(
          code: "confirm_chargeback",
          uid: chargeback_id,
          amount: 500,
          currency: ::Stern.cur("BRL"),
        )
      end

      it "rejects confirming without a prior reintegrate (chargeback_locked is non_negative)" do
        expect {
          described_class.new(**valid_inputs).call
        }.to raise_error(BalanceNonNegativeViolation)
      end

      it "rejects confirming more than was locked" do
        lock_chargeback(amount: 100)

        expect {
          described_class.new(**valid_inputs(amount: 200)).call
        }.to raise_error(BalanceNonNegativeViolation)
      end
    end
  end
end
