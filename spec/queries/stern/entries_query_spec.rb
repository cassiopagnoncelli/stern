require "rails_helper"

module Stern
  RSpec.describe EntriesQuery, type: :model do
    let(:gid) { 1101 }
    let(:brl) { ::Stern.cur("BRL") }
    let(:usd) { ::Stern.cur("USD") }
    let(:operation) { create(:operation) }
    let(:start_date) { 1.day.ago.to_datetime }
    let(:end_date) { 1.day.from_now.to_datetime }

    before { Repair.clear }

    def seed(uid, amount, currency, account = gid)
      EntryPair.add_merchant_balance(uid, account, amount, currency, operation_id: operation.id)
    end

    describe "#call" do
      it "returns only entries matching the requested currency" do
        seed(1, 100, brl)
        seed(2, 50, brl)
        seed(3, 999, usd)

        brl_rows = described_class.new(
          book_id: :merchant_balance, currency: :BRL,
          start_date:, end_date:, gid:,
        ).call
        usd_rows = described_class.new(
          book_id: :merchant_balance, currency: :USD,
          start_date:, end_date:, gid:,
        ).call

        expect(brl_rows.map { |r| r[:amount] }).to match_array([ 100, 50 ])
        expect(usd_rows.map { |r| r[:amount] }).to match_array([ 999 ])
      end

      it "returns an empty list when no entries exist in the currency" do
        seed(1, 100, brl)

        rows = described_class.new(
          book_id: :merchant_balance, currency: :EUR,
          start_date:, end_date:, gid:,
        ).call
        expect(rows).to eq([])
      end

      it "scopes by gid when provided" do
        seed(1, 100, brl, 1101)
        seed(2, 50, brl, 1102)

        rows = described_class.new(
          book_id: :merchant_balance, currency: :BRL,
          start_date:, end_date:, gid: 1101,
        ).call
        expect(rows.map { |r| r[:gid] }).to eq([ 1101 ])
      end

      it "returns entries across gids when gid is omitted" do
        seed(1, 100, brl, 1101)
        seed(2, 50, brl, 1102)

        rows = described_class.new(
          book_id: :merchant_balance, currency: :BRL,
          start_date:, end_date:,
        ).call
        expect(rows.map { |r| r[:gid] }).to match_array([ 1101, 1102 ])
      end

      it "applies code_format to the entry_pair code" do
        seed(1, 100, brl)

        rows = described_class.new(
          book_id: :merchant_balance, currency: :BRL,
          start_date:, end_date:, gid:,
          code_format: %i[titleize drop_first_word],
        ).call
        expect(rows.first[:code]).to eq("Balance")
      end
    end

    describe "pagination" do
      before do
        10.times { |i| seed(i + 1, (i + 1) * 10, brl) }
        seed(100, 999, usd)
      end

      it "returns pages in ascending order for negative pages" do
        rows = described_class.new(
          book_id: :merchant_balance, currency: :BRL,
          start_date:, end_date:, gid:, page: -1, per_page: 3,
        ).call
        expect(rows.size).to eq(3)
        expect(rows.map { |r| r[:amount] }).to eq(rows.map { |r| r[:amount] }.sort)
      end

      it "returns ascending order for positive pages" do
        rows = described_class.new(
          book_id: :merchant_balance, currency: :BRL,
          start_date:, end_date:, gid:, page: 1, per_page: 3,
        ).call
        expect(rows.size).to eq(3)
        expect(rows.map { |r| r[:amount] }).to eq(rows.map { |r| r[:amount] }.sort)
      end
    end

    describe "validation" do
      it "raises on page == 0" do
        expect {
          described_class.new(
            book_id: :merchant_balance, currency: :BRL,
            start_date:, end_date:, page: 0,
          )
        }.to raise_error(ArgumentError, /page cannot be 0/)
      end

      it "raises on non-positive per_page" do
        expect {
          described_class.new(
            book_id: :merchant_balance, currency: :BRL,
            start_date:, end_date:, per_page: 0,
          )
        }.to raise_error(ArgumentError, /per_page must be positive/)
      end

      it "raises on an unknown currency" do
        expect {
          described_class.new(
            book_id: :merchant_balance, currency: "ZZZ",
            start_date:, end_date:,
          )
        }.to raise_error(ArgumentError, /unknown currency/)
      end

      it "raises when currency is nil" do
        expect {
          described_class.new(
            book_id: :merchant_balance, currency: nil,
            start_date:, end_date:,
          )
        }.to raise_error(ArgumentError)
      end
    end
  end
end
