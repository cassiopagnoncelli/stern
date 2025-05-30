require "rails_helper"

module Stern
  RSpec.describe EntryPair, type: :model do
    subject(:entry_pair) { described_class.find_by!(id: entry_pair_id, code:, uid:) }
    let(:entry_pair_id) do
      described_class.double_entry_add(code, gid, uid, book_add, book_sub, amount, nil, timestamp, operation_id)
    end

    let(:code) { "add_#{STERN_DEFS[:entry_pairs].keys.first}" }
    let(:gid) { 1 }
    let(:uid) { Integer(rand * 1e5) }
    let(:book_add) { STERN_DEFS[:entry_pairs].values.first[:book_add] }
    let(:book_sub) { STERN_DEFS[:entry_pairs].values.first[:book_sub] }
    let(:amount) { 100 }
    let(:timestamp) { DateTime.current }
    let(:operation_id) { (create(:operation)).id }

    describe "validations" do
      it { should validate_presence_of(:code) }
      it { should validate_presence_of(:uid) }
      it { should validate_presence_of(:amount) }
      it { should belong_to(:operation) }
      it { should have_many(:entries) }
      it { should belong_to(:operation) }
    end

    describe ".double_entry_add" do
      it "created two entries" do
        expect {
          entry_pair_id
        }.to change(Entry, :count).by(2)
         .and change(described_class, :count).by(1)
      end

      it "stores positive and negative values for the transaction" do
        expect(entry_pair.entries.pluck(:amount)).to include(amount, -amount)
      end

      it "forbids duplicates" do
        expect {
          described_class.double_entry_add(code, gid, uid, book_add, book_sub, amount, nil, timestamp, operation_id)
          described_class.double_entry_add(code, gid, uid, book_add, book_sub, amount, nil, timestamp, operation_id)
        }.to raise_error(ActiveRecord::RecordNotUnique)
      end
    end

    describe ".double_entry_remove" do
      before { entry_pair_id }

      it "destroys the transaction with its entries" do
        expect {
          described_class.double_entry_remove(code, uid, book_add, book_sub)
        }.to change(described_class, :count).by(-1)
        expect { entry_pair }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    describe ".generate_entry_pair_credit_id" do
      it "returns a number" do
        expect(described_class.generate_entry_pair_credit_id).to be_a_kind_of(Integer)
      end
    end
  end
end
