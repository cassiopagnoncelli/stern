require "rails_helper"

module Stern
  RSpec.describe EntryPair, type: :model do
    subject(:entry_pair) { described_class.find_by!(id: entry_pair_id, code:, uid:, currency:) }
    let(:entry_pair_id) do
      described_class.double_entry_add(code, gid, uid, book_add, book_sub, amount, currency, timestamp, operation_id)
    end

    let(:first_pair) { ::Stern.chart.entry_pairs.values.first }
    let(:code) { first_pair.name }
    let(:gid) { 1 }
    let(:uid) { Integer(rand * 1e5) }
    let(:book_add) { first_pair.book_add }
    let(:book_sub) { first_pair.book_sub }
    let(:currency) { ::Stern.cur("BRL") }
    let(:amount) { 100 }
    let(:timestamp) { DateTime.current }
    let(:operation_id) { create(:operation).id }

    describe "validations" do
      it { should validate_presence_of(:code) }
      it { should validate_presence_of(:uid) }
      it { should validate_presence_of(:currency) }
      it { should validate_presence_of(:amount) }
      it { should belong_to(:operation) }
      it { should have_many(:entries) }
    end

    describe ".double_entry_add" do
      it "creates two entries" do
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
          described_class.double_entry_add(code, gid, uid, book_add, book_sub, amount, currency, timestamp, operation_id)
          described_class.double_entry_add(code, gid, uid, book_add, book_sub, amount, currency, timestamp, operation_id)
        }.to raise_error(ActiveRecord::RecordNotUnique)
      end

      it "allows same uid in different currencies" do
        usd = ::Stern.cur("USD")
        described_class.double_entry_add(code, gid, uid, book_add, book_sub, amount, currency, timestamp, operation_id)
        expect {
          described_class.double_entry_add(code, gid, uid, book_add, book_sub, amount, usd, timestamp, operation_id)
        }.to change(described_class, :count).by(1)
      end
    end

    describe ".double_entry_remove" do
      before { entry_pair_id }

      it "destroys the transaction with its entries" do
        expect {
          described_class.double_entry_remove(code, uid, book_add, book_sub, currency)
        }.to change(described_class, :count).by(-1)
        expect { entry_pair }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    describe "chart-derived singleton methods" do
      ::Stern.chart.entry_pairs.each_key do |pair_name|
        it "defines .add_#{pair_name}" do
          expect(described_class).to respond_to(:"add_#{pair_name}")
        end
      end
    end
  end
end
