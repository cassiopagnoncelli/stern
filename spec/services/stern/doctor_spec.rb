require 'rails_helper'

module Stern
  RSpec.describe Doctor, type: :model do
    def uid
      Integer(rand * 1e5)
    end

    def ts
      DateTime.current
    end

    describe ".consistent?" do
      it "always true" do
        expect(described_class.consistent?).to be_truthy
      end
    end

    describe ".rebuild_balances" do
      it "raises error if not confirmed" do
        expect{ described_class.rebuild_balances }.to raise_error(OperationNotConfirmedError)
      end

      it "rebuilds if confirmed" do
        allow(described_class).to receive(:rebuild_gid_balance)
        described_class.rebuild_balances(true)
      end
    end

    describe ".rebuild_gid_balance" do
      it "rebuilds based on gid" do
        expect(described_class).to receive(:rebuild_book_gid_balance).at_least(1).times
        described_class.rebuild_gid_balance(1)
      end
    end

    describe ".rebuild_book_gid_balance" do
      subject(:tx_1) { Tx.double_entry_add(code, gid, uid, book_add, book_sub, amount, nil, ts, false) }
      subject(:tx_2) { Tx.double_entry_add(code, gid, uid, book_add, book_sub, amount, nil, ts, false) }
      subject(:tx_3) { Tx.double_entry_add(code, gid, uid, book_add, book_sub, amount, nil, ts, false) }
      subject(:tx_4) { Tx.double_entry_add(code, gid, uid, book_add, book_sub, amount, nil, ts, false) }
      subject(:tx_5) { Tx.double_entry_add(code, gid, uid, book_add, book_sub, amount, nil, ts, false) }
      subject(:changed_tx) { Tx.find_by!(id: tx_4) }
      subject(:last_tx) { Tx.find_by!(id: tx_5) }
      let(:code) { "add_#{STERN_DEFS[:txs].keys.first}" }
      let(:gid) { 1 }
      let(:book_add) { STERN_DEFS[:txs].values.first[:book_add] }
      let(:book_sub) { STERN_DEFS[:txs].values.first[:book_sub] }
      let(:amount) { 100 }

      before do
        tx_1
        tx_2
        tx_3
        tx_4
        tx_5
      end

      it "executes an SQL query" do
        expect(ActiveRecord::Base.connection).to receive(:execute)
        described_class.rebuild_book_gid_balance(1, 1)
      end

      it "fixes an inconsistent state" do
        expect(described_class.consistent?).to be_truthy
        expect(last_tx.entries.last.ending_balance.abs).to be(5 * amount)

        changed_tx.entries.first.update!(amount: -250, ending_balance: 123)
        changed_tx.entries.last.update!(amount: 250, ending_balance: 123)
        Doctor.rebuild_balances(true)
        last_tx.reload

        # byebug

        expect(last_tx.entries.first.ending_balance.abs).to be(4 * amount + 250)
        expect(last_tx.entries.last.ending_balance.abs).to be(4 * amount + 250)
      end
    end

    describe ".clear" do
      it "clears entries and txs" do
        described_class.clear
        expect(Entry.count).to eq(0)
        expect(Tx.count).to eq(0)
      end
    end
  end
end
