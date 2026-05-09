require "rails_helper"

module Stern
  RSpec.describe AddCredit, type: :model do
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
        expect(described_class.new(**valid_inputs(merchant_id: nil, customer_id: customer_id))).to be_valid
      end

      it "is valid with the partner variant" do
        expect(described_class.new(**valid_inputs(merchant_id: nil, partner_id: partner_id))).to be_valid
      end

      it "rejects when no stakeholder is set" do
        op = described_class.new(**valid_inputs(merchant_id: nil))
        expect(op).not_to be_valid
        expect(op.errors[:base].join).to match(/exactly one of merchant_id, customer_id, partner_id/)
      end

      it "rejects when more than one stakeholder is set" do
        op = described_class.new(**valid_inputs(customer_id: customer_id))
        expect(op).not_to be_valid
      end

      it "rejects a zero amount" do
        op = described_class.new(**valid_inputs(amount: 0))
        expect(op).not_to be_valid
      end

      it "treats an unknown currency as invalid" do
        op = described_class.new(**valid_inputs(currency: "ZZZ"))
        expect(op).not_to be_valid
      end
    end

    describe "#target_tuples" do
      it "merchant: pins merchant_id to merchant_credit pair's two books" do
        op = described_class.new(**valid_inputs)
        expect(op.target_tuples).to eq([
          [ "merchant_credit_0", merchant_id, "BRL" ],
          [ "merchant_credit", merchant_id, "BRL" ]
        ])
      end

      it "customer: switches the pair name to customer_credit" do
        op = described_class.new(**valid_inputs(merchant_id: nil, customer_id: customer_id))
        expect(op.target_tuples).to eq([
          [ "customer_credit_0", customer_id, "BRL" ],
          [ "customer_credit", customer_id, "BRL" ]
        ])
      end
    end

    describe "#call" do
      before { Repair.clear(confirm: true) }

      it "records an Operation row with normalized currency" do
        described_class.new(**valid_inputs).call
        expect(Operation.last).to have_attributes(
          name: "AddCredit",
          params: hash_including("currency" => ::Stern.cur("BRL")),
        )
      end

      it "writes the merchant_credit entry pair keyed by merchant_id" do
        described_class.new(**valid_inputs).call
        expect(EntryPair.last).to have_attributes(
          code: "merchant_credit",
          uid: merchant_id,
          amount: 200,
          currency: ::Stern.cur("BRL"),
        )
      end

      it "increases the merchant's credit balance by amount" do
        described_class.new(**valid_inputs).call
        expect(::Stern.balance(merchant_id, :merchant_credit, :BRL)).to eq(200)
      end

      it "writes customer_credit for the customer variant" do
        described_class.new(**valid_inputs(merchant_id: nil, customer_id: customer_id)).call
        expect(EntryPair.last.code).to eq("customer_credit")
      end

      it "rejects driving merchant_credit negative (book is non_negative)" do
        expect {
          described_class.new(**valid_inputs(amount: -50)).call
        }.to raise_error(BalanceNonNegativeViolation)
      end
    end
  end
end
