require "rails_helper"

module Stern
  RSpec.describe SettleBalance, type: :model do
    let(:merchant_id) { 1101 }
    let(:customer_id) { 2202 }
    let(:partner_id) { 3303 }

    def valid_inputs(**overrides)
      {
        merchant_id:,
        amount: 5000,
        currency: "BRL"
      }.merge(overrides)
    end

    describe "validations" do
      it "is valid with the merchant variant" do
        expect(described_class.new(**valid_inputs)).to be_valid
      end

      it "is valid with the customer variant" do
        op = described_class.new(**valid_inputs(merchant_id: nil, customer_id: customer_id))
        expect(op).to be_valid
      end

      it "is valid with the partner variant" do
        op = described_class.new(**valid_inputs(merchant_id: nil, partner_id: partner_id))
        expect(op).to be_valid
      end

      it "rejects when no stakeholder is set" do
        op = described_class.new(**valid_inputs(merchant_id: nil))
        expect(op).not_to be_valid
        expect(op.errors[:base].join).to match(/exactly one of merchant_id, customer_id, partner_id/)
      end

      it "rejects when more than one stakeholder is set" do
        op = described_class.new(**valid_inputs(customer_id: customer_id))
        expect(op).not_to be_valid
        expect(op.errors[:base].join).to match(/exactly one of/)
      end

      it "rejects a non-positive merchant_id" do
        expect(described_class.new(**valid_inputs(merchant_id: 0))).not_to be_valid
      end

      it "rejects a non-integer merchant_id" do
        expect(described_class.new(**valid_inputs(merchant_id: 1.5))).not_to be_valid
      end

      it "requires an amount" do
        expect(described_class.new(**valid_inputs(amount: nil))).not_to be_valid
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
      it "merchant: pins merchant_id to settle_merchant_balance pair's two books" do
        op = described_class.new(**valid_inputs)
        expect(op.target_tuples).to eq([
          [ "merchant_pending", merchant_id, "BRL" ],
          [ "merchant_available", merchant_id, "BRL" ]
        ])
      end

      it "customer: pins customer_id to settle_customer_balance pair's two books" do
        op = described_class.new(**valid_inputs(merchant_id: nil, customer_id: customer_id))
        expect(op.target_tuples).to eq([
          [ "customer_pending", customer_id, "BRL" ],
          [ "customer_available", customer_id, "BRL" ]
        ])
      end

      it "partner: pins partner_id to settle_partner_balance pair's two books" do
        op = described_class.new(**valid_inputs(merchant_id: nil, partner_id: partner_id))
        expect(op.target_tuples).to eq([
          [ "partner_pending", partner_id, "BRL" ],
          [ "partner_available", partner_id, "BRL" ]
        ])
      end
    end

    describe "#call" do
      before { Repair.clear(confirm: true) }

      it "records an Operation row with normalized currency" do
        described_class.new(**valid_inputs).call
        expect(Operation.last).to have_attributes(
          name: "SettleBalance",
          params: hash_including("currency" => ::Stern.cur("BRL")),
        )
      end

      it "writes one entry pair (settle_merchant_balance) keyed by merchant_id" do
        described_class.new(**valid_inputs).call
        expect(EntryPair.last).to have_attributes(
          code: "settle_merchant_balance",
          uid: merchant_id,
          amount: 5000,
          currency: ::Stern.cur("BRL"),
        )
      end

      it "moves balance from merchant_pending to merchant_available" do
        described_class.new(**valid_inputs).call
        expect(::Stern.balance(merchant_id, :merchant_pending, :BRL)).to eq(-5000)
        expect(::Stern.balance(merchant_id, :merchant_available, :BRL)).to eq(5000)
      end

      it "writes settle_customer_balance for the customer variant" do
        described_class.new(**valid_inputs(merchant_id: nil, customer_id: customer_id)).call
        expect(EntryPair.last.code).to eq("settle_customer_balance")
      end

      it "writes settle_partner_balance for the partner variant" do
        described_class.new(**valid_inputs(merchant_id: nil, partner_id: partner_id)).call
        expect(EntryPair.last.code).to eq("settle_partner_balance")
      end

      it "allows the same merchant_id across two currencies" do
        described_class.new(**valid_inputs(currency: "BRL")).call
        expect {
          described_class.new(**valid_inputs(currency: "USD")).call
        }.to change(EntryPair, :count).by(1)
      end

      it "allows two settles for the same merchant_id and currency" do
        described_class.new(**valid_inputs).call
        expect {
          described_class.new(**valid_inputs(amount: 1000)).call
        }.to change(EntryPair, :count).by(1)
      end
    end
  end
end
