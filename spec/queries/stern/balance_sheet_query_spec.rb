require "rails_helper"

module Stern
  RSpec.describe BalanceSheetQuery, type: :model do
    let(:brl) { ::Stern.cur("BRL") }
    let(:usd) { ::Stern.cur("USD") }
    let(:operation) { create(:operation) }
    let(:start_date) { 1.day.ago.to_datetime }
    let(:end_date) { 1.day.from_now.to_datetime }

    before { Repair.clear }

    def seed(uid, gid, amount, currency)
      EntryPair.add_merchant_available(uid, gid, amount, currency, operation_id: operation.id)
    end

    describe "#call" do
      it "isolates results by currency" do
        seed(1, 1101, 100, brl)
        seed(2, 1101, 500, usd)

        brl_rows = described_class.new(
          start_date:, end_date:, currency: :BRL, book_ids: [ :merchant_available ],
        ).call
        usd_rows = described_class.new(
          start_date:, end_date:, currency: :USD, book_ids: [ :merchant_available ],
        ).call

        brl_mb = brl_rows.find { |r| r[:book_id] == ::Stern.chart.book_code(:merchant_available) }
        usd_mb = usd_rows.find { |r| r[:book_id] == ::Stern.chart.book_code(:merchant_available) }

        expect(brl_mb[:credits]).to eq(100)
        expect(brl_mb[:final_balance]).to eq(100)
        expect(usd_mb[:credits]).to eq(500)
        expect(usd_mb[:final_balance]).to eq(500)
      end

      it "sums credits, debits, and net within the requested currency" do
        seed(1, 1101, 100, brl)
        seed(2, 1101, -30, brl)
        seed(3, 1102, 999, usd)

        rows = described_class.new(
          start_date:, end_date:, currency: :BRL, book_ids: [ :merchant_available ],
        ).call
        mb = rows.find { |r| r[:book_id] == ::Stern.chart.book_code(:merchant_available) }

        expect(mb[:credits]).to eq(100)
        expect(mb[:debits]).to eq(-30)
        expect(mb[:net]).to eq(70)
      end

      it "includes zero rows for books that have no entries in the currency" do
        seed(1, 1101, 100, brl)

        rows = described_class.new(
          start_date:, end_date:, currency: :USD, book_ids: [ :merchant_available ],
        ).call
        mb = rows.find { |r| r[:book_id] == ::Stern.chart.book_code(:merchant_available) }

        expect(mb[:credits]).to eq(0)
        expect(mb[:debits]).to eq(0)
        expect(mb[:net]).to eq(0)
        expect(mb[:final_balance]).to eq(0)
      end

      it "excludes prior balances recorded in a different currency from previous_balance" do
        old = 2.days.ago.to_datetime
        EntryPair.add_merchant_available(1, 1101, 500, usd, timestamp: old, operation_id: operation.id)

        rows = described_class.new(
          start_date: 1.day.ago.to_datetime,
          end_date: 1.day.from_now.to_datetime,
          currency: :BRL,
          book_ids: [ :merchant_available ],
        ).call
        mb = rows.find { |r| r[:book_id] == ::Stern.chart.book_code(:merchant_available) }

        expect(mb[:previous_balance]).to eq(0)
        expect(mb[:final_balance]).to eq(0)
      end

      it "rolls prior balances into previous_balance per book, per gid" do
        old = 2.days.ago.to_datetime
        EntryPair.add_merchant_available(1, 1101, 100, brl, timestamp: old, operation_id: operation.id)
        EntryPair.add_merchant_available(2, 1102, 50, brl, timestamp: old, operation_id: operation.id)

        rows = described_class.new(
          start_date: 1.day.ago.to_datetime,
          end_date: 1.day.from_now.to_datetime,
          currency: :BRL,
          book_ids: [ :merchant_available, :merchant_available_0 ],
        ).call
        mb = rows.find { |r| r[:book_id] == ::Stern.chart.book_code(:merchant_available) }
        mb0 = rows.find { |r| r[:book_id] == ::Stern.chart.book_code(:merchant_available_0) }

        expect(mb[:previous_balance]).to eq(150)
        expect(mb0[:previous_balance]).to eq(-150)
      end
    end

    describe "validation" do
      it "raises on an unknown currency" do
        expect {
          described_class.new(
            start_date:, end_date:, currency: "ZZZ", book_ids: [ :merchant_available ],
          )
        }.to raise_error(ArgumentError, /unknown currency/)
      end

      it "raises when currency is nil" do
        expect {
          described_class.new(
            start_date:, end_date:, currency: nil, book_ids: [ :merchant_available ],
          )
        }.to raise_error(ArgumentError)
      end
    end
  end
end
