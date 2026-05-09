require "rails_helper"

module Stern
  RSpec.describe ReleaseWithheldBalance, type: :model do
    let(:merchant_id) { 1101 }
    let(:customer_id) { 2202 }
    let(:partner_id) { 3303 }

    def valid_inputs(**overrides)
      {
        merchant_id:,
        amount: 2000,
        currency: "BRL"
      }.merge(overrides)
    end

    def seed_withheld(stakeholder_kwargs, amount:, currency: "BRL")
      Deposit.new(amount:, currency:, **stakeholder_kwargs).call
      WithholdBalance.new(amount:, currency:, **stakeholder_kwargs).call
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

      it "rejects a negative amount" do
        op = described_class.new(**valid_inputs(amount: -1000))
        expect(op).not_to be_valid
        expect(op.errors[:amount]).to be_present
      end

      it "treats an unknown currency as invalid" do
        op = described_class.new(**valid_inputs(currency: "ZZZ"))
        expect(op).not_to be_valid
        expect(op.errors[:currency]).to include(/not a recognized currency/)
      end
    end

    describe "#target_tuples" do
      it "merchant: pins merchant_id to release_withheld_merchant_balance pair's two books" do
        op = described_class.new(**valid_inputs)
        expect(op.target_tuples).to eq([
          [ "merchant_withheld", merchant_id, "BRL" ],
          [ "merchant_available", merchant_id, "BRL" ]
        ])
      end

      it "customer: pins customer_id to release_withheld_customer_balance pair's two books" do
        op = described_class.new(**valid_inputs(merchant_id: nil, customer_id:))
        expect(op.target_tuples).to eq([
          [ "customer_withheld", customer_id, "BRL" ],
          [ "customer_available", customer_id, "BRL" ]
        ])
      end

      it "partner: pins partner_id to release_withheld_partner_balance pair's two books" do
        op = described_class.new(**valid_inputs(merchant_id: nil, partner_id:))
        expect(op.target_tuples).to eq([
          [ "partner_withheld", partner_id, "BRL" ],
          [ "partner_available", partner_id, "BRL" ]
        ])
      end
    end

    describe "#call" do
      before { Repair.clear(confirm: true) }

      it "moves balance from merchant_withheld back to merchant_available" do
        seed_withheld({ merchant_id: }, amount: 5000)

        described_class.new(**valid_inputs(amount: 2000)).call

        expect(::Stern.balance(merchant_id, :merchant_withheld, :BRL)).to eq(3000)
        expect(::Stern.balance(merchant_id, :merchant_available, :BRL)).to eq(2000)
      end

      it "writes one entry pair (release_withheld_merchant_balance) keyed by merchant_id" do
        seed_withheld({ merchant_id: }, amount: 5000)

        described_class.new(**valid_inputs(amount: 2000)).call

        expect(EntryPair.last).to have_attributes(
          code: "release_withheld_merchant_balance",
          uid: merchant_id,
          amount: 2000,
          currency: ::Stern.cur("BRL"),
        )
      end

      it "writes release_withheld_customer_balance for the customer variant" do
        seed_withheld({ customer_id: }, amount: 5000)
        described_class.new(**valid_inputs(merchant_id: nil, customer_id:, amount: 2000)).call
        expect(EntryPair.last.code).to eq("release_withheld_customer_balance")
      end

      it "writes release_withheld_partner_balance for the partner variant" do
        seed_withheld({ partner_id: }, amount: 5000)
        described_class.new(**valid_inputs(merchant_id: nil, partner_id:, amount: 2000)).call
        expect(EntryPair.last.code).to eq("release_withheld_partner_balance")
      end

      it "raises InsufficientFunds when amount exceeds withheld balance" do
        seed_withheld({ merchant_id: }, amount: 1000)

        expect {
          described_class.new(**valid_inputs(amount: 5000)).call
        }.to raise_error(::Stern::InsufficientFunds, /exceeds withheld balance/)
      end

      it "does not write any entry pair when the runtime check fails" do
        seed_withheld({ merchant_id: }, amount: 1000)

        expect {
          begin
            described_class.new(**valid_inputs(amount: 5000)).call
          rescue ::Stern::InsufficientFunds
            # expected
          end
        }.not_to change { EntryPair.where(code: "release_withheld_merchant_balance").count }
      end

      it "succeeds when amount equals withheld balance" do
        seed_withheld({ merchant_id: }, amount: 5000)

        described_class.new(**valid_inputs(amount: 5000)).call

        expect(::Stern.balance(merchant_id, :merchant_withheld, :BRL)).to eq(0)
        expect(::Stern.balance(merchant_id, :merchant_available, :BRL)).to eq(5000)
      end
    end
  end
end
