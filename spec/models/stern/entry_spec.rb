require 'rails_helper'

module Stern
  RSpec.describe Entry, type: :model do
    subject(:entry_a) { create(:entry, tx_id: 1, amount: amount_1) }
    subject(:entry_b) { create(:entry, tx_id: 2, amount: amount_2) }
    let(:amount_1) { 9900 }
    let(:amount_2) { -11000 }
    subject(:entry_c) { create(:entry, tx_id: 1, amount: 100) }

    describe "data consistency" do
      before do
        entry_a
        entry_b
      end

      it "has fields filled" do
        expect(entry_a.ending_balance).to be_present
        expect(entry_a.timestamp).to be_present
      end

      it "has ending balance calculated properly" do
        expect(entry_a.ending_balance).to be(amount_1)
        expect(entry_b.ending_balance).to eq(entry_a.ending_balance + amount_2)
      end

      it "forbids duplicate transaction ids in the same book (book_Id) and group (gid)" do
        expect { entry_c }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end

    describe "times, timezones" do
      it "properly sorts entries by the end of the summertime"

      it "keeps ending balance consistent when summertime ends"

      # https://chat.openai.com/chat/674f0ea8-728c-49df-b993-2d320228574b
      it "asserts timestamp delta is minimum"
    end

    context "scopes" do
      before do
        entry_a
        entry_b
      end

      subject(:last_entry_query) do
        described_class.last_entry(entry_b.book_id, entry_b.gid, DateTime.current)
      end

      subject(:next_entries_query) do
        described_class.next_entries(entry_a.book_id, entry_a.gid, entry_a.id, entry_a.timestamp)
      end

      describe ".last_entry" do
        it "should define the scope" do
          expect(described_class).to respond_to(:last_entry)
        end

        it "matches last entry" do
          expect(last_entry_query.length).to be(1)
          expect(last_entry_query.first.ending_balance).to be(entry_b.ending_balance)
          expect(last_entry_query.first.book_id).to be(entry_b.book_id)
          expect(last_entry_query.first.gid).to be(entry_b.gid)
        end
      end

      describe ".next_entries" do
        it "should define the scope" do
          expect(described_class).to respond_to(:next_entries)
        end

        it "returns next entries" do
          expect(next_entries_query.pluck(:id)).to include(entry_b.id)
        end
      end
    end
  end
end
