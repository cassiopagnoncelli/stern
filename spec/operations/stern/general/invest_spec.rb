require "rails_helper"

module Stern
  RSpec.describe Invest, type: :model do
    let(:customer_id) { 2202 }
    let(:investment_id) { 4444 }

    def valid_inputs(**overrides)
      {
        customer_id:,
        investment_id:,
        amount: 1000,
        currency: "BRL"
      }.merge(overrides)
    end

    describe "validations" do
      it "is valid with positive amount" do
        expect(described_class.new(**valid_inputs)).to be_valid
      end

      it "is valid with negative amount (divestment via inverse)" do
        expect(described_class.new(**valid_inputs(amount: -1000))).to be_valid
      end

      it "rejects a missing customer_id" do
        expect(described_class.new(**valid_inputs(customer_id: nil))).not_to be_valid
      end

      it "rejects a missing investment_id" do
        expect(described_class.new(**valid_inputs(investment_id: nil))).not_to be_valid
      end

      it "rejects a non-positive customer_id" do
        expect(described_class.new(**valid_inputs(customer_id: 0))).not_to be_valid
      end

      it "rejects a non-positive investment_id" do
        expect(described_class.new(**valid_inputs(investment_id: 0))).not_to be_valid
      end

      it "rejects a zero amount" do
        expect(described_class.new(**valid_inputs(amount: 0))).not_to be_valid
      end

      it "rejects a nil amount" do
        expect(described_class.new(**valid_inputs(amount: nil))).not_to be_valid
      end

      it "rejects a non-integer amount" do
        expect(described_class.new(**valid_inputs(amount: 1.5))).not_to be_valid
      end

      it "treats an unknown currency as invalid" do
        op = described_class.new(**valid_inputs(currency: "ZZZ"))
        expect(op).not_to be_valid
        expect(op.errors[:currency]).to include(/not a recognized currency/)
      end
    end

    describe "#target_tuples" do
      it "locks customer_available@customer_id and customer_investment@investment_id" do
        op = described_class.new(**valid_inputs)
        expect(op.target_tuples).to eq([
          [ "customer_available",  customer_id,   "BRL" ],
          [ "customer_investment", investment_id, "BRL" ]
        ])
      end
    end

    describe "#call" do
      before { Repair.clear(confirm: true) }

      it "debits customer_available@customer_id and credits customer_investment@investment_id" do
        described_class.new(**valid_inputs(amount: 1000)).call

        expect(::Stern.balance(customer_id,   :customer_available,  :BRL)).to eq(-1000)
        expect(::Stern.balance(investment_id, :customer_investment, :BRL)).to eq(1000)
      end

      it "leaves customer_available@investment_id and customer_investment@customer_id untouched" do
        described_class.new(**valid_inputs(amount: 1000)).call

        expect(::Stern.balance(investment_id, :customer_available,  :BRL)).to eq(0)
        expect(::Stern.balance(customer_id,   :customer_investment, :BRL)).to eq(0)
      end

      it "writes one entry pair (investment_invest) keyed by customer_id" do
        described_class.new(**valid_inputs(amount: 1000)).call

        expect(EntryPair.last).to have_attributes(
          code: "investment_invest",
          uid: customer_id,
          amount: 1000,
          currency: ::Stern.cur("BRL"),
        )
      end

      it "stamps every entry with the operation's currency" do
        described_class.new(**valid_inputs(amount: 1000)).call

        currencies = Entry.where(entry_pair_id: EntryPair.last.id).pluck(:currency).uniq
        expect(currencies).to eq([ ::Stern.cur("BRL") ])
      end

      it "records an Operation row with normalized currency" do
        described_class.new(**valid_inputs).call

        expect(Operation.last).to have_attributes(
          name: "Invest",
          params: hash_including("currency" => ::Stern.cur("BRL")),
        )
      end

      it "reverses sign on a negative amount" do
        described_class.new(**valid_inputs(amount: -500)).call

        expect(::Stern.balance(customer_id,   :customer_available,  :BRL)).to eq(500)
        expect(::Stern.balance(investment_id, :customer_investment, :BRL)).to eq(-500)
      end

      it "allows the same investment_id across two currencies" do
        described_class.new(**valid_inputs(currency: "BRL")).call
        expect {
          described_class.new(**valid_inputs(currency: "USD")).call
        }.to change(EntryPair, :count).by(1)
      end
    end
  end
end
