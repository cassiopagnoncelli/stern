require "rails_helper"

module Stern
  RSpec.describe SumEntriesQuery, type: :model do
    let(:gid) { 1101 }
    let(:brl) { ::Stern.cur("BRL") }
    let(:usd) { ::Stern.cur("USD") }
    let(:operation) { create(:operation) }
    let(:start_date) { 1.day.ago.to_datetime }
    let(:end_date) { 1.day.from_now.to_datetime }

    before { Repair.clear }

    def seed(uid, amount, currency)
      EntryPair.add_merchant_balance(uid, gid, amount, currency, operation_id: operation.id)
    end

    describe "#call" do
      it "sums amounts within the requested currency" do
        seed(1, 100, brl)
        seed(2, 50, brl)
        seed(3, 999, usd)

        brl_rows = described_class.new(
          gid:, book_id: :merchant_balance, currency: :BRL,
          time_grouping: :daily, start_date:, end_date:,
        ).call
        usd_rows = described_class.new(
          gid:, book_id: :merchant_balance, currency: :USD,
          time_grouping: :daily, start_date:, end_date:,
        ).call

        expect(brl_rows.map { |r| r["amount"].to_i }.sum).to eq(150)
        expect(usd_rows.map { |r| r["amount"].to_i }.sum).to eq(999)
      end

      it "returns an empty result when no entries exist in the currency" do
        seed(1, 100, brl)

        rows = described_class.new(
          gid:, book_id: :merchant_balance, currency: :EUR,
          time_grouping: :daily, start_date:, end_date:,
        ).call
        expect(rows).to eq([])
      end

      it "maps the code back to the entry_pair name" do
        seed(1, 100, brl)

        rows = described_class.new(
          gid:, book_id: :merchant_balance, currency: :BRL,
          time_grouping: :daily, start_date:, end_date:,
        ).call
        expect(rows.first["code"]).to eq("merchant_balance")
      end

      it "converts time_window to a DateTime" do
        seed(1, 100, brl)

        rows = described_class.new(
          gid:, book_id: :merchant_balance, currency: :BRL,
          time_grouping: :daily, start_date:, end_date:,
        ).call
        expect(rows.first["time_window"]).to be_a(DateTime)
      end
    end

    describe "validation" do
      it "raises on an unknown currency" do
        expect {
          described_class.new(
            gid:, book_id: :merchant_balance, currency: "ZZZ",
            time_grouping: :daily, start_date:, end_date:,
          )
        }.to raise_error(ArgumentError, /unknown currency/)
      end

      it "raises when currency is nil" do
        expect {
          described_class.new(
            gid:, book_id: :merchant_balance, currency: nil,
            time_grouping: :daily, start_date:, end_date:,
          )
        }.to raise_error(ArgumentError)
      end

      it "raises on an invalid time_grouping" do
        expect {
          described_class.new(
            gid:, book_id: :merchant_balance, currency: :BRL,
            time_grouping: :weird, start_date:, end_date:,
          )
        }.to raise_error(ArgumentError, /invalid grouping/)
      end
    end
  end
end
