require "rails_helper"

module Stern
  RSpec.describe ConfirmWithdrawal, type: :model do
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

    def seed_locked_withdrawal(stakeholder_kwargs, amount:, currency: "BRL")
      Deposit.new(amount:, currency:, **stakeholder_kwargs).call
      LockWithdrawal.new(amount:, currency:, **stakeholder_kwargs).call
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

      it "rejects a non-integer amount" do
        expect(described_class.new(**valid_inputs(amount: 1.5))).not_to be_valid
      end

      it "rejects a missing amount" do
        expect(described_class.new(**valid_inputs(amount: nil))).not_to be_valid
      end

      it "rejects a zero amount" do
        op = described_class.new(**valid_inputs(amount: 0))
        expect(op).not_to be_valid
        expect(op.errors[:amount].join).to match(/greater than 0/)
      end

      it "rejects a negative amount" do
        op = described_class.new(**valid_inputs(amount: -1))
        expect(op).not_to be_valid
        expect(op.errors[:amount].join).to match(/greater than 0/)
      end

      it "treats an unknown currency as invalid" do
        op = described_class.new(**valid_inputs(currency: "ZZZ"))
        expect(op).not_to be_valid
        expect(op.errors[:currency]).to include(/not a recognized currency/)
      end
    end

    describe "#target_tuples" do
      it "merchant: pins merchant_id to confirm_withdrawal_merchant pair's two books" do
        op = described_class.new(**valid_inputs)
        expect(op.target_tuples).to eq([
          [ "wdw_merchant_locked", merchant_id, "BRL" ],
          [ "wdw_merchant_confirmed", merchant_id, "BRL" ]
        ])
      end

      it "customer: pins customer_id to confirm_withdrawal_customer pair's two books" do
        op = described_class.new(**valid_inputs(merchant_id: nil, customer_id:))
        expect(op.target_tuples).to eq([
          [ "wdw_customer_locked", customer_id, "BRL" ],
          [ "wdw_customer_confirmed", customer_id, "BRL" ]
        ])
      end

      it "partner: pins partner_id to confirm_withdrawal_partner pair's two books" do
        op = described_class.new(**valid_inputs(merchant_id: nil, partner_id:))
        expect(op.target_tuples).to eq([
          [ "wdw_partner_locked", partner_id, "BRL" ],
          [ "wdw_partner_confirmed", partner_id, "BRL" ]
        ])
      end
    end

    describe "#call" do
      before { Repair.clear(confirm: true) }

      it "moves balance from wdw_merchant_locked to wdw_merchant_confirmed" do
        seed_locked_withdrawal({ merchant_id: }, amount: 5000)

        described_class.new(**valid_inputs(amount: 5000)).call

        expect(::Stern.balance(merchant_id, :wdw_merchant_locked, :BRL)).to eq(0)
        expect(::Stern.balance(merchant_id, :wdw_merchant_confirmed, :BRL)).to eq(5000)
      end

      it "writes one entry pair (confirm_withdrawal_merchant) keyed by merchant_id" do
        seed_locked_withdrawal({ merchant_id: }, amount: 5000)

        described_class.new(**valid_inputs(amount: 5000)).call

        expect(EntryPair.last).to have_attributes(
          code: "confirm_withdrawal_merchant",
          uid: merchant_id,
          amount: 5000,
          currency: ::Stern.cur("BRL"),
        )
      end

      it "writes confirm_withdrawal_customer for the customer variant" do
        seed_locked_withdrawal({ customer_id: }, amount: 5000)
        described_class.new(**valid_inputs(merchant_id: nil, customer_id:, amount: 5000)).call
        expect(EntryPair.last.code).to eq("confirm_withdrawal_customer")
      end

      it "writes confirm_withdrawal_partner for the partner variant" do
        seed_locked_withdrawal({ partner_id: }, amount: 5000)
        described_class.new(**valid_inputs(merchant_id: nil, partner_id:, amount: 5000)).call
        expect(EntryPair.last.code).to eq("confirm_withdrawal_partner")
      end

      it "supports partial confirmations: confirming 2000 of 5000 leaves 3000 locked" do
        seed_locked_withdrawal({ merchant_id: }, amount: 5000)

        described_class.new(**valid_inputs(amount: 2000)).call

        expect(::Stern.balance(merchant_id, :wdw_merchant_locked, :BRL)).to eq(3000)
        expect(::Stern.balance(merchant_id, :wdw_merchant_confirmed, :BRL)).to eq(2000)
      end

      it "raises InsufficientFunds when amount exceeds the locked balance (non_negative book guard)" do
        seed_locked_withdrawal({ merchant_id: }, amount: 1000)

        expect {
          described_class.new(**valid_inputs(amount: 5000)).call
        }.to raise_error(::Stern::InsufficientFunds)
      end

      it "raises InsufficientFunds when nothing has been locked" do
        expect {
          described_class.new(**valid_inputs).call
        }.to raise_error(::Stern::InsufficientFunds)
      end
    end
  end
end
