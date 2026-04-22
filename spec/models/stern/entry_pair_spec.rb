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

    describe "currency stamping on entries" do
      it "stamps both the add and sub entries with the given currency" do
        entry_pair_id
        entries = Entry.where(entry_pair_id:).order(:amount)
        expect(entries.pluck(:currency).uniq).to eq([ currency ])
      end
    end

    describe "currency-partitioned running balances" do
      let(:usd) { ::Stern.cur("USD") }
      let(:pair) { ::Stern.chart.entry_pairs.values.first }

      it "keeps independent ending_balance across currencies on the add-book" do
        described_class.double_entry_add(pair.name, gid, 1, pair.book_add, pair.book_sub, 100, currency, DateTime.current, operation_id)
        described_class.double_entry_add(pair.name, gid, 2, pair.book_add, pair.book_sub, 300, usd, DateTime.current, operation_id)
        described_class.double_entry_add(pair.name, gid, 3, pair.book_add, pair.book_sub, 25, currency, DateTime.current, operation_id)

        add_book_id = ::Stern.chart.book_code(pair.book_add)
        brl = Entry.where(book_id: add_book_id, gid:, currency:).order(:timestamp, :id).pluck(:ending_balance)
        usd_balances = Entry.where(book_id: add_book_id, gid:, currency: usd).order(:timestamp, :id).pluck(:ending_balance)
        expect(brl).to eq([ 100, 125 ])
        expect(usd_balances).to eq([ 300 ])
      end

      it "keeps independent ending_balance across currencies on the sub-book" do
        described_class.double_entry_add(pair.name, gid, 4, pair.book_add, pair.book_sub, 100, currency, DateTime.current, operation_id)
        described_class.double_entry_add(pair.name, gid, 5, pair.book_add, pair.book_sub, 300, usd, DateTime.current, operation_id)

        sub_book_id = ::Stern.chart.book_code(pair.book_sub)
        brl = Entry.where(book_id: sub_book_id, gid:, currency:).pluck(:ending_balance)
        usd_balances = Entry.where(book_id: sub_book_id, gid:, currency: usd).pluck(:ending_balance)
        expect(brl).to eq([ -100 ])
        expect(usd_balances).to eq([ -300 ])
      end
    end

    describe ".add_<pair_name> via generated singleton" do
      let(:pair) { ::Stern.chart.entry_pairs.values.first }
      let(:method_name) { :"add_#{pair.name}" }

      it "requires currency as a positional argument" do
        expect {
          described_class.public_send(method_name, 101, gid, 100, operation_id:)
        }.to raise_error(ArgumentError)
      end

      it "accepts an integer currency code" do
        expect {
          described_class.public_send(method_name, 101, gid, 100, currency, operation_id:)
        }.to change(Entry, :count).by(2)
      end
    end
  end
end
