require "rails_helper"

module Stern
  RSpec.describe BookBalancesQuery, type: :model do
    let(:brl) { ::Stern.cur("BRL") }
    let(:usd) { ::Stern.cur("USD") }
    let(:operation) { create(:operation) }

    before { Repair.clear }

    def seed(uid, gid, amount, currency)
      EntryPair.add_merchant_balance(uid, gid, amount, currency, operation_id: operation.id)
    end

    it "returns a {gid => balance} map scoped to the currency" do
      seed(1, 1101, 100, brl)
      seed(2, 1102, 50, brl)
      seed(3, 1101, 999, usd)

      brl_map = described_class.new(book_id: :merchant_balance, currency: :BRL).call
      usd_map = described_class.new(book_id: :merchant_balance, currency: :USD).call
      expect(brl_map).to eq(1101 => 100, 1102 => 50)
      expect(usd_map).to eq(1101 => 999)
    end

    it "omits gids that only have entries in a different currency" do
      seed(1, 1101, 100, brl)
      seed(2, 1102, 999, usd)

      map = described_class.new(book_id: :merchant_balance, currency: :BRL).call
      expect(map.keys).to eq([ 1101 ])
    end

    it "returns an empty map when no entries exist in the currency" do
      seed(1, 1101, 100, brl)
      expect(described_class.new(book_id: :merchant_balance, currency: :EUR).call).to eq({})
    end
  end
end
