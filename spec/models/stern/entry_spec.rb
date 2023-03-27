require 'rails_helper'

module Stern
  RSpec.describe Entry, type: :model do
    subject(:entry_a) { create(:entry, tx_id: 1, book_id: 1, amount: 9900) }
    subject(:entry_b) { create(:entry, tx_id: 1, book_id: 2, amount: -9900) }

    describe "transaction pair" do
      it "has present fields" do
        expect(entry_a.ending_balance).to be_present
        expect(entry_a.timestamp).to be_present
        expect(entry_b.ending_balance).to be_present
        expect(entry_b.timestamp).to be_present
      end

      it "has consistent ending balances" do
        expect(entry_a.ending_balance).to be(9900)
        expect(entry_b.ending_balance).to be(-9900)
      end
    end

    describe "scopes" do

    end
  end
end
