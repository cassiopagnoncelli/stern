require "rails_helper"

module Stern
  RSpec.describe Divest, type: :model do
    let(:customer_id) { 2202 }
    let(:investment_id) { 4444 }

    def valid_inputs(**overrides)
      {
        customer_id:,
        investment_id:,
        currency: "BRL"
      }.merge(overrides)
    end

    def seed_invested(amount:, currency: "BRL")
      Invest.new(customer_id:, investment_id:, amount:, currency:).call
    end

    describe "validations" do
      it "is valid with required keys" do
        expect(described_class.new(**valid_inputs)).to be_valid
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
      it "locks customer_available@investment_id (sub side) and customer_investment@customer_id (add side)" do
        op = described_class.new(**valid_inputs)
        expect(op.target_tuples).to eq([
          [ "customer_available",  investment_id, "BRL" ],
          [ "customer_investment", customer_id,   "BRL" ]
        ])
      end
    end

    describe "#call" do
      before { Repair.clear(confirm: true) }

      it "drains the full customer_investment balance back into customer_available" do
        seed_invested(amount: 1000)

        described_class.new(**valid_inputs).call

        expect(::Stern.balance(investment_id, :customer_investment, :BRL)).to eq(0)
        expect(::Stern.balance(investment_id, :customer_available, :BRL)).to eq(0)
      end

      it "writes one entry pair (investment_trade_operation) keyed by customer_id" do
        seed_invested(amount: 1000)

        described_class.new(**valid_inputs).call

        expect(EntryPair.last).to have_attributes(
          code: "investment_trade_operation",
          uid: customer_id,
          amount: -1000,
          currency: ::Stern.cur("BRL"),
        )
      end

      it "is a no-op when the investment balance is zero" do
        expect {
          described_class.new(**valid_inputs).call
        }.not_to change { EntryPair.where(code: "investment_trade_operation").count }
      end

      it "raises InsufficientFunds when allow_overdraft is false and balance is negative" do
        seed_invested(amount: -500)

        expect {
          described_class.new(**valid_inputs).call
        }.to raise_error(::Stern::InsufficientFunds, /negative customer_investment balance -500/)

        expect(::Stern.balance(investment_id, :customer_investment, :BRL)).to eq(-500)
      end

      it "rolls back the Operation row when the runtime check raises" do
        seed_invested(amount: -500)
        operations_before = Operation.where(name: "Divest").count
        entries_before = Entry.count

        expect {
          described_class.new(**valid_inputs).call
        }.to raise_error(::Stern::InsufficientFunds)

        expect(Operation.where(name: "Divest").count).to eq(operations_before)
        expect(Entry.count).to eq(entries_before)
      end

      it "settles a negative investment balance when allow_overdraft is true" do
        seed_invested(amount: -500)

        described_class.new(**valid_inputs(allow_overdraft: true)).call

        expect(::Stern.balance(investment_id, :customer_investment, :BRL)).to eq(0)
      end

      it "writes a positive-amount entry pair when settling a negative balance under allow_overdraft" do
        seed_invested(amount: -500)

        described_class.new(**valid_inputs(allow_overdraft: true)).call

        expect(EntryPair.last).to have_attributes(
          code: "investment_trade_operation",
          uid: customer_id,
          amount: 500,
        )
      end

      it "records an Operation row with normalized currency" do
        seed_invested(amount: 1000)
        described_class.new(**valid_inputs).call

        expect(Operation.last).to have_attributes(
          name: "Divest",
          params: hash_including("currency" => ::Stern.cur("BRL")),
        )
      end
    end
  end
end
