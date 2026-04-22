require "rails_helper"

module Stern
  RSpec.describe BalanceQuery, type: :model do
    let(:gid) { 1101 }
    let(:book_id) { ::Stern.chart.book_code(:merchant_balance) }
    let(:brl) { ::Stern.cur("BRL") }
    let(:usd) { ::Stern.cur("USD") }
    let(:operation) { create(:operation) }

    before { Repair.clear }

    def seed(uid, amount, currency)
      EntryPair.add_merchant_balance(uid, gid, amount, currency, operation_id: operation.id)
    end

    describe "#call" do
      it "returns the ending_balance filtered by currency" do
        seed(1, 100, brl)
        seed(2, 50, brl)
        seed(3, 999, usd)

        brl_balance = described_class.new(gid:, book_id: :merchant_balance, currency: brl, timestamp: DateTime.current).call
        usd_balance = described_class.new(gid:, book_id: :merchant_balance, currency: usd, timestamp: DateTime.current).call
        expect(brl_balance).to eq(150)
        expect(usd_balance).to eq(999)
      end

      it "returns 0 when no entries exist in the requested currency" do
        seed(1, 100, brl)
        eur_balance = described_class.new(gid:, book_id: :merchant_balance, currency: "EUR", timestamp: DateTime.current).call
        expect(eur_balance).to eq(0)
      end

      it "honours the timestamp cutoff" do
        now = DateTime.current
        seed(1, 100, brl)
        sleep 0.01
        cutoff = DateTime.current
        sleep 0.01
        seed(2, 50, brl)

        balance_before = described_class.new(gid:, book_id: :merchant_balance, currency: brl, timestamp: cutoff).call
        balance_after = described_class.new(gid:, book_id: :merchant_balance, currency: brl, timestamp: DateTime.current).call
        expect(balance_before).to eq(100)
        expect(balance_after).to eq(150)
      end
    end

    describe "currency argument forms" do
      before { seed(1, 100, brl) }

      it "accepts a currency name as a String" do
        expect(described_class.new(gid:, book_id: :merchant_balance, currency: "BRL", timestamp: DateTime.current).call).to eq(100)
      end

      it "accepts a currency name as a Symbol" do
        expect(described_class.new(gid:, book_id: :merchant_balance, currency: :BRL, timestamp: DateTime.current).call).to eq(100)
      end

      it "accepts a currency name in lowercase" do
        expect(described_class.new(gid:, book_id: :merchant_balance, currency: "brl", timestamp: DateTime.current).call).to eq(100)
      end

      it "accepts an integer currency index" do
        expect(described_class.new(gid:, book_id: :merchant_balance, currency: brl, timestamp: DateTime.current).call).to eq(100)
      end
    end

    describe "validation" do
      it "raises on an unknown currency string" do
        expect {
          described_class.new(gid:, book_id: :merchant_balance, currency: "ZZZ", timestamp: DateTime.current)
        }.to raise_error(ArgumentError, /unknown currency/)
      end

      it "raises on an unknown currency code" do
        expect {
          described_class.new(gid:, book_id: :merchant_balance, currency: 99_999, timestamp: DateTime.current)
        }.to raise_error(ArgumentError, /unknown currency/)
      end

      it "raises when currency is nil" do
        expect {
          described_class.new(gid:, book_id: :merchant_balance, currency: nil, timestamp: DateTime.current)
        }.to raise_error(ArgumentError)
      end

      it "raises when timestamp is not a Date/DateTime" do
        expect {
          described_class.new(gid:, book_id: :merchant_balance, currency: brl, timestamp: "yesterday")
        }.to raise_error(ArgumentError)
      end
    end

    describe "Stern.balance facade" do
      before { seed(1, 100, brl); seed(2, 7, usd) }

      it "threads currency through to the query" do
        expect(::Stern.balance(gid, :merchant_balance, :BRL)).to eq(100)
        expect(::Stern.balance(gid, :merchant_balance, :USD)).to eq(7)
      end
    end
  end
end
