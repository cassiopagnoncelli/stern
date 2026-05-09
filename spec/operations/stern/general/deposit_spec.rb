require "rails_helper"

module Stern
  RSpec.describe Deposit, type: :model do
    let(:merchant_id) { 1101 }
    let(:customer_id) { 2202 }
    let(:partner_id) { 3303 }

    def valid_inputs(**overrides)
      {
        merchant_id:,
        amount: 1000,
        currency: "BRL"
      }.merge(overrides)
    end

    describe "validations" do
      it "is valid with the merchant variant" do
        expect(described_class.new(**valid_inputs)).to be_valid
      end

      it "is valid with the customer variant" do
        expect(described_class.new(**valid_inputs(merchant_id: nil, customer_id: customer_id))).to be_valid
      end

      it "is valid with the partner variant" do
        expect(described_class.new(**valid_inputs(merchant_id: nil, partner_id: partner_id))).to be_valid
      end

      it "rejects when no stakeholder is set" do
        op = described_class.new(**valid_inputs(merchant_id: nil))
        expect(op).not_to be_valid
        expect(op.errors[:base].join).to match(/exactly one of/)
      end

      it "rejects a zero amount" do
        expect(described_class.new(**valid_inputs(amount: 0))).not_to be_valid
      end

      it "treats an unknown currency as invalid" do
        expect(described_class.new(**valid_inputs(currency: "ZZZ"))).not_to be_valid
      end
    end

    describe "#target_tuples" do
      it "merchant: pins merchant_id to confirm_deposit_merchant pair's two books" do
        op = described_class.new(**valid_inputs)
        expect(op.target_tuples).to eq([
          [ "merchant_deposit", merchant_id, "BRL" ],
          [ "merchant_available", merchant_id, "BRL" ]
        ])
      end

      it "customer variant flips book names to customer_*" do
        op = described_class.new(**valid_inputs(merchant_id: nil, customer_id: customer_id))
        expect(op.target_tuples).to eq([
          [ "customer_deposit", customer_id, "BRL" ],
          [ "customer_available", customer_id, "BRL" ]
        ])
      end
    end

    describe "#call" do
      before { Repair.clear(confirm: true) }

      it "writes the confirm_deposit_merchant entry pair keyed by merchant_id" do
        described_class.new(**valid_inputs).call
        expect(EntryPair.last).to have_attributes(
          code: "confirm_deposit_merchant",
          uid: merchant_id,
          amount: 1000,
          currency: ::Stern.cur("BRL"),
        )
      end

      it "moves balance from merchant_deposit to merchant_available" do
        described_class.new(**valid_inputs).call
        expect(::Stern.balance(merchant_id, :merchant_deposit, :BRL)).to eq(-1000)
        expect(::Stern.balance(merchant_id, :merchant_available, :BRL)).to eq(1000)
      end

      it "writes confirm_deposit_partner for the partner variant" do
        described_class.new(**valid_inputs(merchant_id: nil, partner_id: partner_id)).call
        expect(EntryPair.last.code).to eq("confirm_deposit_partner")
      end

      it "allows two deposits on the same stakeholder" do
        described_class.new(**valid_inputs).call
        expect {
          described_class.new(**valid_inputs(amount: 500)).call
        }.to change(EntryPair, :count).by(1)
        expect(::Stern.balance(merchant_id, :merchant_available, :BRL)).to eq(1500)
      end
    end
  end
end
