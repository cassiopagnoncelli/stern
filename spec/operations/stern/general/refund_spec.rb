require "rails_helper"

module Stern
  RSpec.describe Refund, type: :model do
    let(:merchant_id) { 1101 }
    let(:customer_id) { 2202 }
    let(:refund_id) { 5151 }

    def valid_inputs(**overrides)
      {
        customer_id:,
        refund_id:,
        amount: 700,
        currency: "BRL"
      }.merge(overrides)
    end

    # Refund confirms a previously-locked refund and settles it to the customer.
    # The lock is set up by ReintegratePayment, which `non_negative: true` on
    # `refund_outbound` requires before any confirm/settle can run.
    def lock_refund(amount: 700)
      ReintegratePayment.new(merchant_id:, refund_id:, amount:, currency: "BRL").call
    end

    describe "validations" do
      it "is valid with complete inputs" do
        expect(described_class.new(**valid_inputs)).to be_valid
      end

      it "rejects a missing customer_id" do
        expect(described_class.new(**valid_inputs(customer_id: nil))).not_to be_valid
      end

      it "rejects a missing refund_id" do
        expect(described_class.new(**valid_inputs(refund_id: nil))).not_to be_valid
      end

      it "rejects a zero amount" do
        expect(described_class.new(**valid_inputs(amount: 0))).not_to be_valid
      end

      it "treats an unknown currency as invalid" do
        expect(described_class.new(**valid_inputs(currency: "ZZZ"))).not_to be_valid
      end
    end

    describe "#target_tuples" do
      it "locks confirm_refund at refund_id and settle_refund's two sides" do
        op = described_class.new(**valid_inputs)
        expect(op.target_tuples).to eq([
          [ "refund_outbound",      refund_id,  "BRL" ],
          [ "refund_confirmed",   refund_id,  "BRL" ],
          [ "refund_confirmed",   refund_id,  "BRL" ],
          [ "customer_available", customer_id, "BRL" ]
        ])
      end
    end

    describe "#call" do
      before { Repair.clear(confirm: true) }

      it "drains refund_outbound at refund_id back to zero after confirm + settle" do
        lock_refund(amount: 700)

        described_class.new(**valid_inputs).call

        expect(::Stern.balance(refund_id, :refund_outbound, :BRL)).to eq(0)
      end

      it "credits the customer's available balance by amount" do
        lock_refund(amount: 700)

        described_class.new(**valid_inputs).call

        expect(::Stern.balance(customer_id, :customer_available, :BRL)).to eq(700)
      end

      it "writes both confirm_refund and settle_refund pairs" do
        lock_refund(amount: 700)

        expect {
          described_class.new(**valid_inputs).call
        }.to change(EntryPair, :count).by(2)
      end

      it "rejects confirming more than was locked (refund_outbound is non_negative)" do
        lock_refund(amount: 100)

        expect {
          described_class.new(**valid_inputs(amount: 200)).call
        }.to raise_error(BalanceNonNegativeViolation)
      end

      it "rejects refunding without a prior reintegrate" do
        expect {
          described_class.new(**valid_inputs).call
        }.to raise_error(BalanceNonNegativeViolation)
      end
    end
  end
end
