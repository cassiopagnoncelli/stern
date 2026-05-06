require "rails_helper"

module Stern
  RSpec.describe ChargePixFeeMerchant, type: :model do
    let(:merchant_id) { 1101 }

    def valid_inputs(**overrides)
      {
        merchant_id:,
        fee: 100,
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

      it "requires a fee" do
        op = described_class.new(**valid_inputs(fee: nil))
        expect(op).not_to be_valid
        expect(op.errors[:fee]).to be_present
      end

      it "rejects a zero fee" do
        op = described_class.new(**valid_inputs(fee: 0))
        expect(op).not_to be_valid
        expect(op.errors[:fee]).to be_present
      end

      it "rejects a non-integer fee" do
        expect(described_class.new(**valid_inputs(fee: 1.5))).not_to be_valid
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
          name: "ChargePixFeeMerchant",
          params: hash_including("currency" => ::Stern.cur("BRL")),
        )
      end

      it "writes one entry pair (charge_pix_fee_merchant)" do
        expect { described_class.new(**valid_inputs).call }.to change(EntryPair, :count).by(1)
      end

      it "writes the charge_pix_fee_merchant pair keyed by merchant_id" do
        described_class.new(**valid_inputs).call
        pair = EntryPair.last
        expect(pair).to have_attributes(
          code: "charge_pix_fee_merchant",
          uid: merchant_id,
          amount: 100,
          currency: ::Stern.cur("BRL"),
        )
      end

      it "debits merchant_available and credits payment_fee" do
        described_class.new(**valid_inputs).call
        expect(::Stern.balance(merchant_id, :merchant_available, :BRL)).to eq(-100)
        expect(::Stern.balance(merchant_id, :payment_fee, :BRL)).to eq(100)
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

      it "allows re-running for the same merchant_id and currency" do
        described_class.new(**valid_inputs).call
        expect {
          described_class.new(**valid_inputs(fee: 200)).call
        }.to change(EntryPair, :count).by(1)
      end
    end
  end
end
