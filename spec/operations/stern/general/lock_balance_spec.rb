require "rails_helper"

module Stern
  RSpec.describe LockBalance, type: :model do
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

    def seed_available(stakeholder_kwargs, amount:, currency: "BRL")
      Deposit.new(amount:, currency:, **stakeholder_kwargs).call
    end

    describe "validations" do
      it "is valid with the merchant variant" do
        expect(described_class.new(**valid_inputs)).to be_valid
      end

      it "is valid with the customer variant" do
        op = described_class.new(**valid_inputs(merchant_id: nil, customer_id:))
        expect(op).to be_valid
      end

      it "is valid with the partner variant" do
        op = described_class.new(**valid_inputs(merchant_id: nil, partner_id:))
        expect(op).to be_valid
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
        op = described_class.new(**valid_inputs(amount: -5000))
        expect(op).not_to be_valid
        expect(op.errors[:amount]).to be_present
      end

      it "treats an unknown currency as invalid" do
        op = described_class.new(**valid_inputs(currency: "ZZZ"))
        expect(op).not_to be_valid
        expect(op.errors[:currency]).to include(/not a recognized currency/)
      end

      it "defaults allow_overdraft to false when omitted" do
        expect(described_class.new(**valid_inputs).allow_overdraft).to eq(false)
      end

      it "rejects a non-boolean allow_overdraft" do
        expect(described_class.new(**valid_inputs(allow_overdraft: "yes"))).not_to be_valid
      end
    end

    describe "#target_tuples" do
      it "merchant: pins merchant_id to lock_merchant_balance pair's two books" do
        op = described_class.new(**valid_inputs)
        expect(op.target_tuples).to eq([
          [ "merchant_available", merchant_id, "BRL" ],
          [ "merchant_outbound", merchant_id, "BRL" ]
        ])
      end

      it "customer: pins customer_id to lock_customer_balance pair's two books" do
        op = described_class.new(**valid_inputs(merchant_id: nil, customer_id:))
        expect(op.target_tuples).to eq([
          [ "customer_available", customer_id, "BRL" ],
          [ "customer_outbound", customer_id, "BRL" ]
        ])
      end

      it "partner: pins partner_id to lock_partner_balance pair's two books" do
        op = described_class.new(**valid_inputs(merchant_id: nil, partner_id:))
        expect(op.target_tuples).to eq([
          [ "partner_available", partner_id, "BRL" ],
          [ "partner_outbound", partner_id, "BRL" ]
        ])
      end
    end

    describe "#call" do
      before { Repair.clear(confirm: true) }

      it "moves balance from merchant_available to merchant_outbound" do
        seed_available({ merchant_id: }, amount: 10_000)

        described_class.new(**valid_inputs(amount: 5000)).call

        expect(::Stern.balance(merchant_id, :merchant_available, :BRL)).to eq(5000)
        expect(::Stern.balance(merchant_id, :merchant_outbound, :BRL)).to eq(5000)
      end

      it "writes one entry pair (lock_merchant_balance) keyed by merchant_id" do
        seed_available({ merchant_id: }, amount: 10_000)

        described_class.new(**valid_inputs(amount: 5000)).call

        expect(EntryPair.last).to have_attributes(
          code: "lock_merchant_balance",
          uid: merchant_id,
          amount: 5000,
          currency: ::Stern.cur("BRL"),
        )
      end

      it "writes lock_customer_balance for the customer variant" do
        seed_available({ customer_id: }, amount: 10_000)
        described_class.new(**valid_inputs(merchant_id: nil, customer_id:, amount: 5000)).call
        expect(EntryPair.last.code).to eq("lock_customer_balance")
      end

      it "writes lock_partner_balance for the partner variant" do
        seed_available({ partner_id: }, amount: 10_000)
        described_class.new(**valid_inputs(merchant_id: nil, partner_id:, amount: 5000)).call
        expect(EntryPair.last.code).to eq("lock_partner_balance")
      end

      context "when overdraft disallowed (default)" do
        it "raises InsufficientFunds when amount exceeds available balance" do
          seed_available({ merchant_id: }, amount: 1000)

          expect {
            described_class.new(**valid_inputs(amount: 5000)).call
          }.to raise_error(::Stern::InsufficientFunds, /exceeds available balance/)
        end

        it "does not write any entry pair when the runtime check fails" do
          seed_available({ merchant_id: }, amount: 1000)

          expect {
            begin
              described_class.new(**valid_inputs(amount: 5000)).call
            rescue ::Stern::InsufficientFunds
              # expected
            end
          }.not_to change { EntryPair.where(code: "lock_merchant_balance").count }
        end

        it "does not commit an Operation row when the runtime check fails" do
          seed_available({ merchant_id: }, amount: 1000)

          expect {
            begin
              described_class.new(**valid_inputs(amount: 5000)).call
            rescue ::Stern::InsufficientFunds
              # expected
            end
          }.not_to change { Operation.where(name: "LockBalance").count }
        end

        it "succeeds when amount equals available balance" do
          seed_available({ merchant_id: }, amount: 5000)

          described_class.new(**valid_inputs(amount: 5000)).call

          expect(::Stern.balance(merchant_id, :merchant_available, :BRL)).to eq(0)
          expect(::Stern.balance(merchant_id, :merchant_outbound, :BRL)).to eq(5000)
        end
      end

      context "when allow_overdraft is true" do
        it "allows amount > available_balance and drives available negative" do
          seed_available({ merchant_id: }, amount: 1000)

          described_class.new(**valid_inputs(amount: 5000, allow_overdraft: true)).call

          expect(::Stern.balance(merchant_id, :merchant_available, :BRL)).to eq(-4000)
          expect(::Stern.balance(merchant_id, :merchant_outbound, :BRL)).to eq(5000)
        end

        it "skips the runtime check entirely with no available balance seeded" do
          described_class.new(**valid_inputs(amount: 5000, allow_overdraft: true)).call

          expect(::Stern.balance(merchant_id, :merchant_available, :BRL)).to eq(-5000)
          expect(::Stern.balance(merchant_id, :merchant_outbound, :BRL)).to eq(5000)
        end
      end
    end
  end
end
