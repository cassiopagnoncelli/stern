require "rails_helper"

module Stern
  RSpec.describe OutstandingBalanceQuery, type: :model do
    let(:book_id) { ::Stern.chart.book_code(:merchant_balance) }
    let(:brl) { ::Stern.cur("BRL") }
    let(:usd) { ::Stern.cur("USD") }
    let(:operation) { create(:operation) }

    before { Repair.clear }

    def seed(uid, gid, amount, currency)
      EntryPair.add_merchant_balance(uid, gid, amount, currency, operation_id: operation.id)
    end

    describe "#call" do
      it "sums ending_balance across accounts within one currency" do
        seed(1, 1101, 100, brl)
        seed(2, 1102, 50, brl)
        seed(3, 1103, 999, usd)

        expect(described_class.new(book_id: :merchant_balance, currency: :BRL).call).to eq(150)
        expect(described_class.new(book_id: :merchant_balance, currency: :USD).call).to eq(999)
      end

      it "returns 0 when there are no entries in the currency" do
        seed(1, 1101, 100, brl)
        expect(described_class.new(book_id: :merchant_balance, currency: :EUR).call).to eq(0)
      end

      it "uses the latest ending_balance per gid, not a sum of amounts" do
        seed(1, 1101, 100, brl)
        seed(2, 1101, -30, brl)  # same gid, so latest ending_balance = 70
        seed(3, 1102, 10, brl)

        expect(described_class.new(book_id: :merchant_balance, currency: :BRL).call).to eq(80)
      end

      it "honours the timestamp cutoff per currency" do
        seed(1, 1101, 100, brl)
        seed(2, 1101, 500, usd)
        sleep 0.01
        cutoff = DateTime.current
        sleep 0.01
        seed(3, 1102, 50, brl)
        seed(4, 1102, 200, usd)

        expect(described_class.new(book_id: :merchant_balance, currency: :BRL, timestamp: cutoff).call).to eq(100)
        expect(described_class.new(book_id: :merchant_balance, currency: :USD, timestamp: cutoff).call).to eq(500)
      end
    end
  end
end
