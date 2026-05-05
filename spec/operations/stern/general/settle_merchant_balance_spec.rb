require "rails_helper"

module Stern
  RSpec.describe SettleMerchantBalance, type: :model do
    let(:merchant_id) { 1101 }

    def valid_inputs(**overrides)
      {
        merchant_id:,
        amount: 5000,
        currency: "BRL"
      }.merge(overrides)
    end

    describe "validations" do
      it "is valid with complete inputs" do
        expect(described_class.new(**valid_inputs)).to be_valid
      end

      it "requires a merchant_id" do
        op = described_class.new(**valid_inputs(merchant_id: nil))
        expect(op).not_to be_valid
        expect(op.errors[:merchant_id]).to be_present
      end

      it "rejects a non-positive merchant_id" do
        expect(described_class.new(**valid_inputs(merchant_id: 0))).not_to be_valid
        expect(described_class.new(**valid_inputs(merchant_id: -1))).not_to be_valid
      end

      it "rejects a non-integer merchant_id" do
        expect(described_class.new(**valid_inputs(merchant_id: 1.5))).not_to be_valid
      end

      it "requires an amount" do
        op = described_class.new(**valid_inputs(amount: nil))
        expect(op).not_to be_valid
        expect(op.errors[:amount]).to be_present
      end

      it "rejects a zero amount" do
        op = described_class.new(**valid_inputs(amount: 0))
        expect(op).not_to be_valid
        expect(op.errors[:amount]).to be_present
      end

      it "rejects a non-integer amount" do
        expect(described_class.new(**valid_inputs(amount: 1.5))).not_to be_valid
      end

      it "requires a currency" do
        op = described_class.new(**valid_inputs(currency: nil))
        expect(op).not_to be_valid
        expect(op.errors[:currency]).to be_present
      end

      it "rejects a blank currency string" do
        expect { described_class.new(**valid_inputs(currency: "")) }.to raise_error(UnknownCurrencyError)
      end
    end

    describe "currency normalization" do
      it "converts a currency string to its integer index" do
        op = described_class.new(**valid_inputs(currency: "brl"))
        expect(op.currency).to eq(::Stern.cur("BRL"))
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
          name: "SettleMerchantBalance",
          params: hash_including("currency" => ::Stern.cur("BRL")),
        )
      end

      it "writes one entry pair (settle_merchant_balance)" do
        expect { described_class.new(**valid_inputs).call }.to change(EntryPair, :count).by(1)
      end

      it "writes the settle_merchant_balance pair keyed by merchant_id" do
        described_class.new(**valid_inputs).call
        pair = EntryPair.last
        expect(pair).to have_attributes(
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

      it "stamps every entry with the operation's currency" do
        described_class.new(**valid_inputs).call
        currencies = Entry.where(entry_pair_id: EntryPair.last.id).pluck(:currency).uniq
        expect(currencies).to eq([ ::Stern.cur("BRL") ])
      end

      it "allows the same merchant_id across two currencies" do
        described_class.new(**valid_inputs(currency: "BRL")).call
        expect {
          described_class.new(**valid_inputs(currency: "USD")).call
        }.to change(EntryPair, :count).by(1)
      end

      it "rejects re-running for the same merchant_id and currency" do
        described_class.new(**valid_inputs).call
        expect {
          described_class.new(**valid_inputs(amount: 1000)).call
        }.to raise_error(ActiveRecord::RecordInvalid, /Uid has already been taken/)
      end
    end
  end
end
