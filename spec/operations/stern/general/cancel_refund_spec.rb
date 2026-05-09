require "rails_helper"

module Stern
  RSpec.describe CancelRefund, type: :model do
    let(:merchant_id) { 1101 }
    let(:partner_id) { 3303 }
    let(:refund_id) { 5151 }

    def valid_inputs(**overrides)
      {
        merchant_id:,
        refund_id:,
        amount: 700,
        currency: "BRL"
      }.merge(overrides)
    end

    describe "validations" do
      it "is valid with merchant + refund" do
        expect(described_class.new(**valid_inputs)).to be_valid
      end

      it "is valid with partner + refund" do
        expect(described_class.new(**valid_inputs(merchant_id: nil, partner_id:))).to be_valid
      end

      it "rejects when no funder is set" do
        op = described_class.new(**valid_inputs(merchant_id: nil))
        expect(op).not_to be_valid
        expect(op.errors[:base].join).to match(/exactly one of merchant_id, partner_id/)
      end

      it "rejects when both funders are set" do
        op = described_class.new(**valid_inputs(partner_id:))
        expect(op).not_to be_valid
      end

      it "rejects a missing refund_id" do
        expect(described_class.new(**valid_inputs(refund_id: nil))).not_to be_valid
      end

      it "rejects a zero amount" do
        expect(described_class.new(**valid_inputs(amount: 0))).not_to be_valid
      end

      it "rejects a negative amount" do
        expect(described_class.new(**valid_inputs(amount: -1))).not_to be_valid
      end

      it "treats an unknown currency as invalid" do
        expect(described_class.new(**valid_inputs(currency: "ZZZ"))).not_to be_valid
      end
    end

    describe "#target_tuples" do
      it "merchant: locks refund_locked at refund_id and merchant_available at merchant_id" do
        op = described_class.new(**valid_inputs)
        expect(op.target_tuples).to eq([
          [ "refund_locked",      refund_id,   "BRL" ],
          [ "merchant_available", merchant_id, "BRL" ]
        ])
      end

      it "partner: locks refund_locked at refund_id and partner_available at partner_id" do
        op = described_class.new(**valid_inputs(merchant_id: nil, partner_id:))
        expect(op.target_tuples).to eq([
          [ "refund_locked",     refund_id,  "BRL" ],
          [ "partner_available", partner_id, "BRL" ]
        ])
      end
    end

    describe "#call" do
      before { Repair.clear(confirm: true) }

      it "drains refund_locked at refund_id back to zero" do
        ReintegratePayment.new(merchant_id:, refund_id:, amount: 700, currency: "BRL").call

        described_class.new(**valid_inputs).call

        expect(::Stern.balance(refund_id, :refund_locked, :BRL)).to eq(0)
      end

      it "credits merchant_available at refund_id back by amount (undoes the lock)" do
        ReintegratePayment.new(merchant_id:, refund_id:, amount: 700, currency: "BRL").call

        described_class.new(**valid_inputs).call

        expect(::Stern.balance(refund_id, :merchant_available, :BRL)).to eq(0)
      end

      it "credits partner_available at refund_id back by amount for partner-funded refunds" do
        ReintegratePayment.new(partner_id:, refund_id:, amount: 700, currency: "BRL").call

        described_class.new(**valid_inputs(merchant_id: nil, partner_id:)).call

        expect(::Stern.balance(refund_id, :partner_available, :BRL)).to eq(0)
      end

      it "writes cancel_refund_merchant for merchant-funded refunds" do
        ReintegratePayment.new(merchant_id:, refund_id:, amount: 700, currency: "BRL").call

        described_class.new(**valid_inputs).call

        expect(EntryPair.last).to have_attributes(
          code: "cancel_refund_merchant",
          uid: merchant_id,
          amount: 700,
          currency: ::Stern.cur("BRL"),
        )
      end

      it "writes cancel_refund_partner for partner-funded refunds" do
        ReintegratePayment.new(partner_id:, refund_id:, amount: 700, currency: "BRL").call

        described_class.new(**valid_inputs(merchant_id: nil, partner_id:)).call

        expect(EntryPair.last.code).to eq("cancel_refund_partner")
      end

      it "supports partial cancels: cancelling 300 of 700 leaves 400 locked" do
        ReintegratePayment.new(merchant_id:, refund_id:, amount: 700, currency: "BRL").call

        described_class.new(**valid_inputs(amount: 300)).call

        expect(::Stern.balance(refund_id, :refund_locked, :BRL)).to eq(400)
      end

      it "rejects cancelling more than was locked (refund_locked is non_negative)" do
        ReintegratePayment.new(merchant_id:, refund_id:, amount: 100, currency: "BRL").call

        expect {
          described_class.new(**valid_inputs(amount: 200)).call
        }.to raise_error(::Stern::InsufficientFunds)
      end

      it "rejects cancelling a refund that was never locked" do
        expect {
          described_class.new(**valid_inputs).call
        }.to raise_error(::Stern::InsufficientFunds)
      end

      it "after confirm_refund drains refund_locked, cancel no longer applies" do
        ReintegratePayment.new(merchant_id:, refund_id:, amount: 700, currency: "BRL").call
        Refund.new(customer_id: 2202, refund_id:, amount: 700, currency: "BRL").call

        expect {
          described_class.new(**valid_inputs).call
        }.to raise_error(::Stern::InsufficientFunds)
      end
    end
  end
end
