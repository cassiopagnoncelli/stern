require "rails_helper"

module Stern
  RSpec.describe Trade, type: :model do
    let(:investment_id) { 4444 }

    def valid_inputs(**overrides)
      {
        investment_id:,
        amount: 800,
        fee: 20,
        currency: "BRL"
      }.merge(overrides)
    end

    describe "validations" do
      it "is valid with positive amount and fee" do
        expect(described_class.new(**valid_inputs)).to be_valid
      end

      it "is valid with zero amount when fee is non-zero" do
        expect(described_class.new(**valid_inputs(amount: 0))).to be_valid
      end

      it "is valid with zero fee" do
        expect(described_class.new(**valid_inputs(fee: 0))).to be_valid
      end

      it "rejects nil amount" do
        expect(described_class.new(**valid_inputs(amount: nil))).not_to be_valid
      end

      it "rejects nil fee" do
        expect(described_class.new(**valid_inputs(fee: nil))).not_to be_valid
      end

      it "rejects a non-integer amount" do
        expect(described_class.new(**valid_inputs(amount: 1.5))).not_to be_valid
      end

      it "rejects a non-positive investment_id" do
        expect(described_class.new(**valid_inputs(investment_id: 0))).not_to be_valid
      end

      it "treats an unknown currency as invalid" do
        expect(described_class.new(**valid_inputs(currency: "ZZZ"))).not_to be_valid
      end
    end

    describe "#target_tuples" do
      it "locks both pairs when amount and fee are both non-zero" do
        op = described_class.new(**valid_inputs)
        expect(op.target_tuples).to eq([
          [ "customer_trade",     investment_id, "BRL" ],
          [ "customer_investment", investment_id, "BRL" ],
          [ "customer_trade_fee", investment_id, "BRL" ],
          [ "customer_investment", investment_id, "BRL" ]
        ])
      end

      it "skips the trade pair when amount is zero" do
        op = described_class.new(**valid_inputs(amount: 0))
        expect(op.target_tuples).to eq([
          [ "customer_trade_fee", investment_id, "BRL" ],
          [ "customer_investment", investment_id, "BRL" ]
        ])
      end

      it "skips the fee pair when fee is zero" do
        op = described_class.new(**valid_inputs(fee: 0))
        expect(op.target_tuples).to eq([
          [ "customer_trade",      investment_id, "BRL" ],
          [ "customer_investment", investment_id, "BRL" ]
        ])
      end

      it "returns no tuples when both amount and fee are zero" do
        op = described_class.new(**valid_inputs(amount: 0, fee: 0))
        expect(op.target_tuples).to eq([])
      end
    end

    describe "#call" do
      before { Repair.clear }

      it "writes investment_trade and investment_trade_fee pairs" do
        expect {
          described_class.new(**valid_inputs).call
        }.to change(EntryPair, :count).by(2)
      end

      it "credits customer_investment by amount and debits customer_trade by amount" do
        described_class.new(**valid_inputs(amount: 800, fee: 0)).call
        expect(::Stern.balance(investment_id, :customer_investment, :BRL)).to eq(800)
        expect(::Stern.balance(investment_id, :customer_trade, :BRL)).to eq(-800)
      end

      it "debits customer_investment by fee and credits customer_trade_fee by fee" do
        described_class.new(**valid_inputs(amount: 0, fee: 20)).call
        expect(::Stern.balance(investment_id, :customer_investment, :BRL)).to eq(-20)
        expect(::Stern.balance(investment_id, :customer_trade_fee, :BRL)).to eq(20)
      end

      it "nets to (amount - fee) on customer_investment when both run" do
        described_class.new(**valid_inputs(amount: 800, fee: 20)).call
        expect(::Stern.balance(investment_id, :customer_investment, :BRL)).to eq(780)
      end

      it "is a no-op when both amount and fee are zero" do
        expect {
          described_class.new(**valid_inputs(amount: 0, fee: 0)).call
        }.not_to change(EntryPair, :count)
      end
    end
  end
end
