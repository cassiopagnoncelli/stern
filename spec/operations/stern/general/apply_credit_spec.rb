require "rails_helper"

module Stern
  RSpec.describe ApplyCredit, type: :model do
    let(:merchant_id) { 1101 }
    let(:customer_id) { 2202 }
    let(:partner_id) { 3303 }

    def valid_inputs(**overrides)
      {
        merchant_id:,
        amount: 200,
        currency: "BRL"
      }.merge(overrides)
    end

    describe "validations" do
      it "is valid with the merchant variant" do
        expect(described_class.new(**valid_inputs)).to be_valid
      end

      it "is valid with the customer variant" do
        expect(described_class.new(**valid_inputs(merchant_id: nil, customer_id:))).to be_valid
      end

      it "is valid with the partner variant" do
        expect(described_class.new(**valid_inputs(merchant_id: nil, partner_id:))).to be_valid
      end

      it "is valid with a negative amount (reverse application)" do
        expect(described_class.new(**valid_inputs(amount: -200))).to be_valid
      end

      it "rejects when no stakeholder is set" do
        op = described_class.new(**valid_inputs(merchant_id: nil))
        expect(op).not_to be_valid
        expect(op.errors[:base].join).to match(/exactly one of merchant_id, customer_id, partner_id/)
      end

      it "rejects when more than one stakeholder is set" do
        op = described_class.new(**valid_inputs(customer_id:))
        expect(op).not_to be_valid
        expect(op.errors[:base].join).to match(/exactly one of/)
      end

      it "rejects a zero amount" do
        op = described_class.new(**valid_inputs(amount: 0))
        expect(op).not_to be_valid
        expect(op.errors[:amount]).to be_present
      end

      it "rejects a non-integer amount" do
        expect(described_class.new(**valid_inputs(amount: 1.5))).not_to be_valid
      end

      it "treats an unknown currency as invalid" do
        op = described_class.new(**valid_inputs(currency: "ZZZ"))
        expect(op).not_to be_valid
        expect(op.errors[:currency]).to include(/not a recognized currency/)
      end
    end

    describe "#target_tuples" do
      it "merchant: pins merchant_id to apply_merchant_credit pair's two books" do
        op = described_class.new(**valid_inputs)
        expect(op.target_tuples).to eq([
          [ "merchant_credit", merchant_id, "BRL" ],
          [ "merchant_available", merchant_id, "BRL" ]
        ])
      end

      it "customer: pins customer_id to apply_customer_credit pair's two books" do
        op = described_class.new(**valid_inputs(merchant_id: nil, customer_id:))
        expect(op.target_tuples).to eq([
          [ "customer_credit", customer_id, "BRL" ],
          [ "customer_available", customer_id, "BRL" ]
        ])
      end

      it "partner: pins partner_id to apply_partner_credit pair's two books" do
        op = described_class.new(**valid_inputs(merchant_id: nil, partner_id:))
        expect(op.target_tuples).to eq([
          [ "partner_credit", partner_id, "BRL" ],
          [ "partner_available", partner_id, "BRL" ]
        ])
      end
    end

    describe "#call" do
      before { Repair.clear(confirm: true) }

      it "moves balance from merchant_credit to merchant_available on a positive amount" do
        AddCredit.new(merchant_id:, amount: 500, currency: "BRL").call

        described_class.new(**valid_inputs(amount: 200)).call

        expect(::Stern.balance(merchant_id, :merchant_credit, :BRL)).to eq(300)
        expect(::Stern.balance(merchant_id, :merchant_available, :BRL)).to eq(200)
      end

      it "reverses direction on a negative amount" do
        AddCredit.new(merchant_id:, amount: 500, currency: "BRL").call

        described_class.new(**valid_inputs(amount: -200)).call

        expect(::Stern.balance(merchant_id, :merchant_credit, :BRL)).to eq(700)
        expect(::Stern.balance(merchant_id, :merchant_available, :BRL)).to eq(-200)
      end

      it "writes one entry pair (apply_merchant_credit) keyed by merchant_id" do
        AddCredit.new(merchant_id:, amount: 500, currency: "BRL").call

        described_class.new(**valid_inputs(amount: 200)).call

        expect(EntryPair.last).to have_attributes(
          code: "apply_merchant_credit",
          uid: merchant_id,
          amount: 200,
          currency: ::Stern.cur("BRL"),
        )
      end

      it "writes apply_customer_credit for the customer variant" do
        AddCredit.new(customer_id:, amount: 500, currency: "BRL").call
        described_class.new(**valid_inputs(merchant_id: nil, customer_id:, amount: 200)).call
        expect(EntryPair.last.code).to eq("apply_customer_credit")
      end

      it "writes apply_partner_credit for the partner variant" do
        AddCredit.new(partner_id:, amount: 500, currency: "BRL").call
        described_class.new(**valid_inputs(merchant_id: nil, partner_id:, amount: 200)).call
        expect(EntryPair.last.code).to eq("apply_partner_credit")
      end

      it "records an Operation row with normalized currency" do
        AddCredit.new(merchant_id:, amount: 500, currency: "BRL").call
        described_class.new(**valid_inputs).call

        expect(Operation.last).to have_attributes(
          name: "ApplyCredit",
          params: hash_including("currency" => ::Stern.cur("BRL")),
        )
      end
    end
  end
end
