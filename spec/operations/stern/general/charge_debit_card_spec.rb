require "rails_helper"

module Stern
  RSpec.describe ChargeDebitCard, type: :model do
    let(:merchant_id) { 1101 }
    let(:customer_id) { 2202 }

    def valid_inputs(**overrides)
      {
        charge_id: 9001,
        merchant_id:,
        customer_id:,
        amount: 9900,
        currency: "BRL"
      }.merge(overrides)
    end

    describe "validations" do
      it "is valid with complete inputs" do
        expect(described_class.new(**valid_inputs)).to be_valid
      end

      it "requires a currency" do
        op = described_class.new(**valid_inputs(currency: nil))
        expect(op).not_to be_valid
        expect(op.errors[:currency]).to be_present
      end

      it "rejects a blank currency string" do
        expect { described_class.new(**valid_inputs(currency: "")) }.to raise_error(UnknownCurrencyError)
      end

      it "requires a charge_id" do
        op = described_class.new(**valid_inputs(charge_id: nil))
        expect(op).not_to be_valid
      end

      it "requires an amount" do
        op = described_class.new(**valid_inputs(amount: nil))
        expect(op).not_to be_valid
      end
    end

    describe "currency normalization" do
      it "converts a currency string to its integer index" do
        op = described_class.new(**valid_inputs(currency: "brl"))
        expect(op.currency).to eq(::Stern.cur("BRL"))
      end

      it "is case-insensitive" do
        upper = described_class.new(**valid_inputs(currency: "USD")).currency
        lower = described_class.new(**valid_inputs(currency: "usd")).currency
        expect(upper).to eq(lower)
        expect(upper).to eq(::Stern.cur("USD"))
      end

      it "raises on an unknown currency" do
        expect { described_class.new(**valid_inputs(currency: "ZZZ")) }.to raise_error(UnknownCurrencyError)
      end
    end

    describe "#call" do
      before { Repair.clear }

      it "records an Operation row with currency in params" do
        described_class.new(**valid_inputs).call
        expect(Operation.last).to have_attributes(
          name: "ChargeDebitCard",
          params: hash_including("currency" => ::Stern.cur("BRL")),
        )
      end

      it "writes two entry pairs (charge + unidentified customer) when no customer_id" do
        expect { described_class.new(**valid_inputs).call }.to change(EntryPair, :count).by(2)
      end

      it "writes the double entry stamped with currency" do
        described_class.new(**valid_inputs).call
        entries = Entry.where(entry_pair_id: EntryPair.last.id)
        expect(entries.count).to eq(2)
        expect(entries.pluck(:currency).uniq).to eq([ ::Stern.cur("BRL") ])
      end

      it "keeps BRL and USD balances fully independent for the same merchant" do
        described_class.new(**valid_inputs(charge_id: 1, amount: 9900, currency: "BRL")).call
        described_class.new(**valid_inputs(charge_id: 2, amount: 5000, currency: "USD")).call
        described_class.new(**valid_inputs(charge_id: 3, amount: 1000, currency: "BRL")).call

        brl = ::Stern.balance(merchant_id, :pp_charge_debit_card, :BRL)
        usd = ::Stern.balance(merchant_id, :pp_charge_debit_card, :USD)
        expect(brl).to eq(10_900)
        expect(usd).to eq(5000)
      end

      it "allows the same charge_id to exist in two currencies" do
        described_class.new(**valid_inputs(charge_id: 7, currency: "BRL")).call
        expect {
          described_class.new(**valid_inputs(charge_id: 7, currency: "USD")).call
        }.to change(EntryPair, :count).by(2)
      end

      context "with customer_id" do
        it "writes to identified_customer instead of unidentified_customer" do
          expect {
            described_class.new(**valid_inputs(customer_id: 5001)).call
          }.to change(EntryPair, :count).by(2)
        end

        it "records the amount in the pp_charge_identified_customer book keyed by customer_id" do
          described_class.new(**valid_inputs(charge_id: 20, customer_id: 5001)).call
          balance = ::Stern.balance(5001, :pp_charge_identified_customer, :BRL)
          expect(balance).to eq(-9900)
        end

        it "records the amount in the pp_charge_unidentified_customer book keyed by merchant_id when customer_id is nil" do
          described_class.new(**valid_inputs(charge_id: 21, customer_id: nil)).call
          balance = ::Stern.balance(merchant_id, :pp_charge_unidentified_customer, :BRL)
          expect(balance).to eq(-9900)
        end

        it "rejects a non-positive customer_id" do
          op = described_class.new(**valid_inputs(customer_id: 0))
          expect(op).not_to be_valid
          expect(op.errors[:customer_id]).to be_present
        end
      end

      context "with a fee" do
        it "writes an additional fee entry pair when fee is positive" do
          expect {
            described_class.new(**valid_inputs(fee: 100)).call
          }.to change(EntryPair, :count).by(3)
        end

        it "records the fee in the pp_charge_fee_merchant_debit_card book" do
          described_class.new(**valid_inputs(charge_id: 11, fee: 100)).call
          fee_balance = ::Stern.balance(merchant_id, :pp_charge_fee_merchant_debit_card, :BRL)
          expect(fee_balance).to eq(100)
        end

        it "does not write a fee entry pair when fee is zero" do
          expect {
            described_class.new(**valid_inputs(fee: 0)).call
          }.to change(EntryPair, :count).by(2)
        end

        it "does not write a fee entry pair when fee is nil" do
          expect {
            described_class.new(**valid_inputs).call
          }.to change(EntryPair, :count).by(2)
        end
      end
    end
  end
end
