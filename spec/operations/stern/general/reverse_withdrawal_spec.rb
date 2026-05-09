require "rails_helper"

module Stern
  RSpec.describe ReverseWithdrawal, type: :model do
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

    def seed_confirmed(stakeholder_kwargs, amount:, currency: "BRL")
      Deposit.new(amount:, currency:, **stakeholder_kwargs).call
      LockWithdrawal.new(amount:, currency:, **stakeholder_kwargs).call
      ConfirmWithdrawal.new(amount:, currency:, **stakeholder_kwargs).call
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
    end

    describe "#target_tuples" do
      it "merchant: pins merchant_id to reverse_withdrawal_merchant pair's two books" do
        op = described_class.new(**valid_inputs)
        expect(op.target_tuples).to eq([
          [ "wdw_merchant_confirmed", merchant_id, "BRL" ],
          [ "merchant_available", merchant_id, "BRL" ]
        ])
      end

      it "customer: pins customer_id to reverse_withdrawal_customer pair's two books" do
        op = described_class.new(**valid_inputs(merchant_id: nil, customer_id:))
        expect(op.target_tuples).to eq([
          [ "wdw_customer_confirmed", customer_id, "BRL" ],
          [ "customer_available", customer_id, "BRL" ]
        ])
      end

      it "partner: pins partner_id to reverse_withdrawal_partner pair's two books" do
        op = described_class.new(**valid_inputs(merchant_id: nil, partner_id:))
        expect(op.target_tuples).to eq([
          [ "wdw_partner_confirmed", partner_id, "BRL" ],
          [ "partner_available", partner_id, "BRL" ]
        ])
      end
    end

    describe "#call" do
      before { Repair.clear }

      it "moves balance from wdw_merchant_confirmed back to merchant_available" do
        seed_confirmed({ merchant_id: }, amount: 5000)

        described_class.new(**valid_inputs(amount: 2000)).call

        expect(::Stern.balance(merchant_id, :wdw_merchant_confirmed, :BRL)).to eq(3000)
        expect(::Stern.balance(merchant_id, :merchant_available, :BRL)).to eq(2000)
      end

      it "writes one entry pair (reverse_withdrawal_merchant) keyed by merchant_id" do
        seed_confirmed({ merchant_id: }, amount: 5000)

        described_class.new(**valid_inputs(amount: 2000)).call

        expect(EntryPair.last).to have_attributes(
          code: "reverse_withdrawal_merchant",
          uid: merchant_id,
          amount: 2000,
          currency: ::Stern.cur("BRL"),
        )
      end

      it "writes reverse_withdrawal_customer for the customer variant" do
        seed_confirmed({ customer_id: }, amount: 5000)
        described_class.new(**valid_inputs(merchant_id: nil, customer_id:, amount: 2000)).call
        expect(EntryPair.last.code).to eq("reverse_withdrawal_customer")
      end

      it "writes reverse_withdrawal_partner for the partner variant" do
        seed_confirmed({ partner_id: }, amount: 5000)
        described_class.new(**valid_inputs(merchant_id: nil, partner_id:, amount: 2000)).call
        expect(EntryPair.last.code).to eq("reverse_withdrawal_partner")
      end

      it "raises InsufficientFunds when amount exceeds confirmed balance" do
        seed_confirmed({ merchant_id: }, amount: 1000)

        expect {
          described_class.new(**valid_inputs(amount: 5000)).call
        }.to raise_error(::Stern::InsufficientFunds, /exceeds confirmed balance/)
      end

      it "does not write any entry pair when the runtime check fails" do
        seed_confirmed({ merchant_id: }, amount: 1000)

        expect {
          begin
            described_class.new(**valid_inputs(amount: 5000)).call
          rescue ::Stern::InsufficientFunds
            # expected
          end
        }.not_to change { EntryPair.where(code: "reverse_withdrawal_merchant").count }
      end

      it "succeeds when amount equals confirmed balance" do
        seed_confirmed({ merchant_id: }, amount: 5000)

        described_class.new(**valid_inputs(amount: 5000)).call

        expect(::Stern.balance(merchant_id, :wdw_merchant_confirmed, :BRL)).to eq(0)
        expect(::Stern.balance(merchant_id, :merchant_available, :BRL)).to eq(5000)
      end
    end
  end
end
