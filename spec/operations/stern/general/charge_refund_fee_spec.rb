require "rails_helper"

module Stern
  RSpec.describe ChargeRefundFee, type: :model do
    let(:merchant_id) { 1101 }
    let(:partner_id) { 3303 }

    def valid_inputs(**overrides)
      {
        merchant_id:,
        amount: 100,
        currency: "BRL"
      }.merge(overrides)
    end

    describe "validations" do
      it "is valid with the merchant variant" do
        expect(described_class.new(**valid_inputs)).to be_valid
      end

      it "is valid with the partner variant" do
        expect(described_class.new(**valid_inputs(merchant_id: nil, partner_id:))).to be_valid
      end

      it "rejects when no stakeholder is set" do
        op = described_class.new(**valid_inputs(merchant_id: nil))
        expect(op).not_to be_valid
        expect(op.errors[:base].join).to match(/exactly one of merchant_id, partner_id/)
      end

      it "rejects when both stakeholders are set" do
        op = described_class.new(**valid_inputs(partner_id:))
        expect(op).not_to be_valid
        expect(op.errors[:base].join).to match(/exactly one of/)
      end

      it "rejects a zero amount" do
        expect(described_class.new(**valid_inputs(amount: 0))).not_to be_valid
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
      it "merchant: locks fee pair and credit pair tuples" do
        op = described_class.new(**valid_inputs)
        expect(op.target_tuples).to eq([
          [ "merchant_available",  merchant_id, "BRL" ],
          [ "refund_fee_merchant", merchant_id, "BRL" ],
          [ "merchant_credit",     merchant_id, "BRL" ],
          [ "merchant_available",  merchant_id, "BRL" ]
        ])
      end

      it "partner: locks fee pair and credit pair tuples" do
        op = described_class.new(**valid_inputs(merchant_id: nil, partner_id:))
        expect(op.target_tuples).to eq([
          [ "partner_available",  partner_id, "BRL" ],
          [ "refund_fee_partner", partner_id, "BRL" ],
          [ "partner_credit",     partner_id, "BRL" ],
          [ "partner_available",  partner_id, "BRL" ]
        ])
      end
    end

    describe "#call" do
      before { Repair.clear }

      it "debits merchant_available and credits refund_fee_merchant by amount" do
        described_class.new(**valid_inputs(amount: 100)).call

        expect(::Stern.balance(merchant_id, :merchant_available, :BRL)).to eq(-100)
        expect(::Stern.balance(merchant_id, :refund_fee_merchant, :BRL)).to eq(100)
      end

      it "writes one entry pair (charge_refund_fee_merchant) keyed by merchant_id" do
        described_class.new(**valid_inputs(amount: 100)).call

        expect(EntryPair.last).to have_attributes(
          code: "charge_refund_fee_merchant",
          uid: merchant_id,
          amount: 100,
          currency: ::Stern.cur("BRL"),
        )
      end

      it "writes charge_refund_fee_partner for the partner variant" do
        described_class.new(**valid_inputs(merchant_id: nil, partner_id:, amount: 100)).call
        expect(EntryPair.last.code).to eq("charge_refund_fee_partner")
      end

      it "records an Operation row with normalized currency" do
        described_class.new(**valid_inputs).call

        expect(Operation.last).to have_attributes(
          name: "ChargeRefundFee",
          params: hash_including("currency" => ::Stern.cur("BRL")),
        )
      end

      it "reverses sign on a negative amount (fee reversal)" do
        described_class.new(**valid_inputs(amount: -100)).call

        expect(::Stern.balance(merchant_id, :merchant_available, :BRL)).to eq(100)
        expect(::Stern.balance(merchant_id, :refund_fee_merchant, :BRL)).to eq(-100)
      end

      context "with available credit" do
        it "applies partial credit when balance < fee, debiting available by the net" do
          AddCredit.new(merchant_id:, amount: 30, currency: "BRL").call

          expect {
            described_class.new(**valid_inputs(amount: 100)).call
          }.to change(EntryPair, :count).by(2)

          expect(::Stern.balance(merchant_id, :merchant_credit, :BRL)).to eq(0)
          expect(::Stern.balance(merchant_id, :merchant_available, :BRL)).to eq(-70)
          expect(::Stern.balance(merchant_id, :refund_fee_merchant, :BRL)).to eq(100)
        end

        it "caps credit at the fee amount when balance > fee" do
          AddCredit.new(merchant_id:, amount: 500, currency: "BRL").call

          described_class.new(**valid_inputs(amount: 100)).call

          expect(::Stern.balance(merchant_id, :merchant_credit, :BRL)).to eq(400)
          expect(::Stern.balance(merchant_id, :merchant_available, :BRL)).to eq(0)
        end

        it "skips credit application when the credit balance is zero" do
          expect {
            described_class.new(**valid_inputs(amount: 100)).call
          }.to change(EntryPair, :count).by(1)

          expect(::Stern.balance(merchant_id, :merchant_credit, :BRL)).to eq(0)
        end

        it "skips credit application for negative amounts (fee reversal)" do
          AddCredit.new(merchant_id:, amount: 30, currency: "BRL").call

          expect {
            described_class.new(**valid_inputs(amount: -50)).call
          }.to change(EntryPair, :count).by(1)

          expect(::Stern.balance(merchant_id, :merchant_credit, :BRL)).to eq(30)
        end

        it "applies partner credit for the partner variant" do
          AddCredit.new(partner_id:, amount: 70, currency: "BRL").call

          described_class.new(**valid_inputs(merchant_id: nil, partner_id:, amount: 100)).call

          expect(::Stern.balance(partner_id, :partner_credit, :BRL)).to eq(0)
          expect(::Stern.balance(partner_id, :partner_available, :BRL)).to eq(-30)
          expect(::Stern.balance(partner_id, :refund_fee_partner, :BRL)).to eq(100)
        end

        it "only consumes credit in the operation's currency" do
          AddCredit.new(merchant_id:, amount: 50, currency: "USD").call

          described_class.new(**valid_inputs(amount: 100, currency: "BRL")).call

          expect(::Stern.balance(merchant_id, :merchant_credit, :USD)).to eq(50)
          expect(::Stern.balance(merchant_id, :merchant_credit, :BRL)).to eq(0)
        end
      end
    end
  end
end
