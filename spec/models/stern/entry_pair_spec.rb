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

    describe "book-derived singleton methods" do
      STERN_DEFS[:books].each_key do |book_name|
        it "defines .add_#{book_name}" do
          expect(described_class).to respond_to(:"add_#{book_name}")
        end
      end

      it "does not collide with entry_pair names" do
        expect(STERN_DEFS[:entry_pairs].keys & STERN_DEFS[:books].keys).to eq([])
      end
    end

    describe ".add_<book> (forward/backward)" do
      let(:book_name) { STERN_DEFS[:books].keys.first }
      let(:book_code) { STERN_DEFS[:books][book_name] }
      let(:uid) { Integer(rand * 1e5) }
      let(:gid) { 1 }
      let(:amount) { 100 }
      let(:timestamp) { DateTime.current }
      let(:operation_id) { create(:operation).id }
      let(:credit_entry_pair_id) { nil }

      it "issues a forward and a backward double_entry_add with mirrored book codes" do
        expect(described_class).to receive(:double_entry_add).with(
          "add_#{book_name}", gid, uid,
          book_code, -book_code,
          amount, credit_entry_pair_id, timestamp, operation_id,
        ).ordered
        expect(described_class).to receive(:double_entry_add).with(
          "sub_#{book_name}", gid, uid,
          -book_code, book_code,
          amount, credit_entry_pair_id, timestamp, operation_id,
        ).ordered

        described_class.public_send(
          :"add_#{book_name}", uid, gid, amount, credit_entry_pair_id,
          timestamp: timestamp, operation_id: operation_id,
        )
      end

      it "defaults credit_entry_pair_id, timestamp and operation_id when omitted" do
        expect(described_class).to receive(:double_entry_add).with(
          "add_#{book_name}", gid, uid, book_code, -book_code, amount, nil, nil, nil,
        ).ordered
        expect(described_class).to receive(:double_entry_add).with(
          "sub_#{book_name}", gid, uid, -book_code, book_code, amount, nil, nil, nil,
        ).ordered

        described_class.public_send(:"add_#{book_name}", uid, gid, amount)
      end
    end
  end
end
