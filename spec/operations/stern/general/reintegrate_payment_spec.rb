require "rails_helper"

module Stern
  RSpec.describe ReintegratePayment, type: :model do
    let(:merchant_id) { 1101 }
    let(:partner_id) { 3303 }
    let(:refund_id) { 5151 }
    let(:chargeback_id) { 6262 }

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

      it "is valid with partner + chargeback" do
        op = described_class.new(**valid_inputs(merchant_id: nil, partner_id: partner_id, refund_id: nil, chargeback_id: chargeback_id))
        expect(op).to be_valid
      end

      it "rejects when no stakeholder is set" do
        op = described_class.new(**valid_inputs(merchant_id: nil))
        expect(op).not_to be_valid
        expect(op.errors[:base].join).to match(/exactly one of merchant_id, partner_id/)
      end

      it "rejects when both stakeholders are set" do
        op = described_class.new(**valid_inputs(partner_id: partner_id))
        expect(op).not_to be_valid
      end

      it "rejects when no target is set" do
        op = described_class.new(**valid_inputs(refund_id: nil))
        expect(op).not_to be_valid
        expect(op.errors[:base].join).to match(/exactly one of refund_id, chargeback_id/)
      end

      it "rejects when both targets are set" do
        op = described_class.new(**valid_inputs(chargeback_id: chargeback_id))
        expect(op).not_to be_valid
      end

      it "rejects a zero amount" do
        expect(described_class.new(**valid_inputs(amount: 0))).not_to be_valid
      end

      it "treats an unknown currency as invalid" do
        expect(described_class.new(**valid_inputs(currency: "ZZZ"))).not_to be_valid
      end
    end

    describe "#target_tuples" do
      it "merchant + refund: locks merchant_available at merchant_id, refund_locked at refund_id" do
        op = described_class.new(**valid_inputs)
        expect(op.target_tuples).to eq([
          [ "merchant_available", merchant_id, "BRL" ],
          [ "refund_locked",      refund_id,  "BRL" ]
        ])
      end

      it "partner + chargeback: locks partner_available at partner_id, chargeback_locked at chargeback_id" do
        op = described_class.new(**valid_inputs(merchant_id: nil, partner_id: partner_id, refund_id: nil, chargeback_id: chargeback_id))
        expect(op.target_tuples).to eq([
          [ "partner_available",  partner_id,    "BRL" ],
          [ "chargeback_locked",  chargeback_id, "BRL" ]
        ])
      end
    end

    describe "#call" do
      before { Repair.clear(confirm: true) }

      it "credits refund_locked@refund_id and debits merchant_available@merchant_id" do
        described_class.new(**valid_inputs).call
        expect(::Stern.balance(refund_id,   :refund_locked,      :BRL)).to eq(700)
        expect(::Stern.balance(merchant_id, :merchant_available, :BRL)).to eq(-700)
        # Cross-gid leakage is zero.
        expect(::Stern.balance(refund_id,   :merchant_available, :BRL)).to eq(0)
        expect(::Stern.balance(merchant_id, :refund_locked,      :BRL)).to eq(0)
      end

      it "writes lock_refund_merchant for merchant + refund" do
        described_class.new(**valid_inputs).call
        expect(EntryPair.last).to have_attributes(
          code: "lock_refund_merchant",
          uid: merchant_id,
          amount: 700,
          currency: ::Stern.cur("BRL"),
        )
      end

      it "writes lock_chargeback_partner for partner + chargeback" do
        described_class.new(**valid_inputs(merchant_id: nil, partner_id: partner_id, refund_id: nil, chargeback_id: chargeback_id)).call
        expect(EntryPair.last.code).to eq("lock_chargeback_partner")
      end

      it "rejects releasing more than was locked (refund_locked is non_negative)" do
        described_class.new(**valid_inputs(amount: 700)).call

        expect {
          described_class.new(**valid_inputs(amount: -1000)).call
        }.to raise_error(BalanceNonNegativeViolation)
      end
    end
  end
end
