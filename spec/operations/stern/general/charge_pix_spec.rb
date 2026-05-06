require "rails_helper"

module Stern
  RSpec.describe ChargePix, type: :model do
    let(:charge_id) { 9001 }
    let(:payment_id) { 7001 }
    let(:merchant_id) { 1101 }
    let(:customer_id) { 2202 }

    def valid_inputs(**overrides)
      {
        charge_id:,
        payment_id:,
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

      it "is valid with customer_id omitted" do
        expect(described_class.new(**valid_inputs(customer_id: nil))).to be_valid
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

      it "rejects a non-positive charge_id" do
        expect(described_class.new(**valid_inputs(charge_id: 0))).not_to be_valid
        expect(described_class.new(**valid_inputs(charge_id: -1))).not_to be_valid
      end

      it "rejects a non-integer charge_id" do
        expect(described_class.new(**valid_inputs(charge_id: 1.5))).not_to be_valid
      end

      it "requires a payment_id" do
        op = described_class.new(**valid_inputs(payment_id: nil))
        expect(op).not_to be_valid
        expect(op.errors[:payment_id]).to be_present
      end

      it "rejects a non-positive payment_id" do
        expect(described_class.new(**valid_inputs(payment_id: 0))).not_to be_valid
        expect(described_class.new(**valid_inputs(payment_id: -1))).not_to be_valid
      end

      it "rejects a non-integer payment_id" do
        expect(described_class.new(**valid_inputs(payment_id: 1.5))).not_to be_valid
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

      it "rejects a non-positive customer_id when present" do
        op = described_class.new(**valid_inputs(customer_id: 0))
        expect(op).not_to be_valid
        expect(op.errors[:customer_id]).to be_present
      end

      it "requires an amount" do
        op = described_class.new(**valid_inputs(amount: nil))
        expect(op).not_to be_valid
      end

      it "rejects a zero amount" do
        op = described_class.new(**valid_inputs(amount: 0))
        expect(op).not_to be_valid
        expect(op.errors[:amount]).to be_present
      end

      it "rejects a non-integer amount" do
        op = described_class.new(**valid_inputs(amount: 99.5))
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
          name: "ChargePix",
          params: hash_including("currency" => ::Stern.cur("BRL")),
        )
      end

      it "writes one entry pair (charge_pix)" do
        expect { described_class.new(**valid_inputs).call }.to change(EntryPair, :count).by(1)
      end

      it "writes the charge_pix pair keyed by payment_id" do
        described_class.new(**valid_inputs).call
        pair = EntryPair.last
        expect(pair).to have_attributes(
          code: "charge_pix",
          uid: payment_id,
          amount: 9900,
          currency: ::Stern.cur("BRL"),
        )
      end

      it "stamps every entry with the operation's currency" do
        described_class.new(**valid_inputs).call
        currencies = Entry.where(entry_pair_id: EntryPair.last.id).pluck(:currency).uniq
        expect(currencies).to eq([ ::Stern.cur("BRL") ])
      end

      it "credits the payment book and debits charged_pix for the same payment_id" do
        described_class.new(**valid_inputs).call
        expect(::Stern.balance(payment_id, :payment, :BRL)).to eq(9900)
        expect(::Stern.balance(payment_id, :charged_pix, :BRL)).to eq(-9900)
      end

      it "keeps BRL and USD balances fully independent for the same payment" do
        described_class.new(**valid_inputs(charge_id: 1, amount: 9900, currency: "BRL")).call
        described_class.new(
          **valid_inputs(charge_id: 2, payment_id: payment_id + 1, amount: 5000, currency: "USD"),
        ).call

        expect(::Stern.balance(payment_id, :payment, :BRL)).to eq(9900)
        expect(::Stern.balance(payment_id + 1, :payment, :USD)).to eq(5000)
      end

      it "allows the same payment_id across two currencies" do
        described_class.new(**valid_inputs(currency: "BRL")).call
        expect {
          described_class.new(**valid_inputs(currency: "USD")).call
        }.to change(EntryPair, :count).by(1)
      end

      it "succeeds with customer_id omitted" do
        expect {
          described_class.new(**valid_inputs(customer_id: nil)).call
        }.to change(EntryPair, :count).by(1)
      end

      it "allows re-running for the same payment_id and currency" do
        described_class.new(**valid_inputs).call
        expect {
          described_class.new(**valid_inputs(charge_id: charge_id + 1)).call
        }.to change(EntryPair, :count).by(1)
      end
    end
  end
end
