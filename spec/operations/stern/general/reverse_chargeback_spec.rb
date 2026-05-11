require "rails_helper"

module Stern
  RSpec.describe ReverseChargeback, type: :model do
    let(:merchant_id) { 1101 }
    let(:partner_id) { 3303 }
    let(:chargeback_id) { 6262 }

    def valid_inputs(**overrides)
      {
        merchant_id:,
        chargeback_id:,
        amount: 500,
        currency: "BRL"
      }.merge(overrides)
    end

    # Drives chargeback_loss to `amount` at chargeback_id, funded by the
    # given stakeholder.
    def confirm_chargeback(funder_kwargs, amount: 500)
      ReintegratePayment.new(chargeback_id:, amount:, currency: "BRL", **funder_kwargs).call
      Chargeback.new(chargeback_id:, amount:, currency: "BRL").call
    end

    describe "validations" do
      it "is valid with the merchant variant" do
        expect(described_class.new(**valid_inputs)).to be_valid
      end

      it "is valid with the partner variant" do
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

      it "rejects a missing chargeback_id" do
        expect(described_class.new(**valid_inputs(chargeback_id: nil))).not_to be_valid
      end

      it "rejects a zero amount" do
        op = described_class.new(**valid_inputs(amount: 0))
        expect(op).not_to be_valid
        expect(op.errors[:amount]).to be_present
      end

      it "rejects a negative amount" do
        op = described_class.new(**valid_inputs(amount: -1))
        expect(op).not_to be_valid
        expect(op.errors[:amount]).to be_present
      end

      it "treats an unknown currency as invalid" do
        expect(described_class.new(**valid_inputs(currency: "ZZZ"))).not_to be_valid
      end
    end

    describe "#target_tuples" do
      it "merchant: locks chargeback_loss@chargeback_id and merchant_available@merchant_id" do
        op = described_class.new(**valid_inputs)
        expect(op.target_tuples).to eq([
          [ "chargeback_loss",    chargeback_id, "BRL" ],
          [ "merchant_available", merchant_id,   "BRL" ]
        ])
      end

      it "partner: locks chargeback_loss@chargeback_id and partner_available@partner_id" do
        op = described_class.new(**valid_inputs(merchant_id: nil, partner_id:))
        expect(op.target_tuples).to eq([
          [ "chargeback_loss",   chargeback_id, "BRL" ],
          [ "partner_available", partner_id,    "BRL" ]
        ])
      end
    end

    describe "#call" do
      before { Repair.clear(confirm: true) }

      it "credits merchant_available@merchant_id and drains chargeback_loss@chargeback_id" do
        confirm_chargeback({ merchant_id: }, amount: 500)

        described_class.new(**valid_inputs(amount: 500)).call

        # Full reversal returns the merchant to neutral (the -500 debit from
        # reintegrate is now cancelled by the +500 reverse credit) and
        # zeroes the loss book.
        expect(::Stern.balance(merchant_id,   :merchant_available, :BRL)).to eq(0)
        expect(::Stern.balance(chargeback_id, :chargeback_loss,    :BRL)).to eq(0)
      end

      it "credits partner_available@partner_id and drains chargeback_loss@chargeback_id for partner-funded chargebacks" do
        confirm_chargeback({ partner_id: }, amount: 500)

        described_class.new(**valid_inputs(merchant_id: nil, partner_id:, amount: 500)).call

        expect(::Stern.balance(partner_id,    :partner_available, :BRL)).to eq(0)
        expect(::Stern.balance(chargeback_id, :chargeback_loss,   :BRL)).to eq(0)
      end

      it "writes one reverse_chargeback_merchant entry pair keyed by chargeback_id" do
        confirm_chargeback({ merchant_id: }, amount: 500)

        described_class.new(**valid_inputs(amount: 500)).call

        expect(EntryPair.last).to have_attributes(
          code: "reverse_chargeback_merchant",
          uid: chargeback_id,
          amount: 500,
          currency: ::Stern.cur("BRL"),
        )
      end

      it "writes reverse_chargeback_partner for the partner variant" do
        confirm_chargeback({ partner_id: }, amount: 500)

        described_class.new(**valid_inputs(merchant_id: nil, partner_id:, amount: 500)).call

        expect(EntryPair.last.code).to eq("reverse_chargeback_partner")
      end

      it "supports partial reversal: 300 of 500 leaves merchant_available@merchant_id at -200 and chargeback_loss@chargeback_id at 200" do
        confirm_chargeback({ merchant_id: }, amount: 500)

        described_class.new(**valid_inputs(amount: 300)).call

        # confirm debited merchant_available by 500 and credited chargeback_loss by 500;
        # the partial reverse credits 300 back and drains 300 of the loss.
        expect(::Stern.balance(merchant_id,   :merchant_available, :BRL)).to eq(-200)
        expect(::Stern.balance(chargeback_id, :chargeback_loss,    :BRL)).to eq(200)
      end

      it "is idempotent under the same idem_key with identical params" do
        confirm_chargeback({ merchant_id: }, amount: 500)

        first  = described_class.new(**valid_inputs(amount: 300)).call(idem_key: "rev-cb-#{chargeback_id}")
        second = described_class.new(**valid_inputs(amount: 300)).call(idem_key: "rev-cb-#{chargeback_id}")

        expect(second).to eq(first)
        expect(EntryPair.where(code: "reverse_chargeback_merchant").count).to eq(1)
      end
    end
  end
end
