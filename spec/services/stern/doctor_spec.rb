require 'rails_helper'

module Stern
  RSpec.describe Doctor, type: :model do
    def uid
      Integer(rand * 1e5)
    end

    def ts
      DateTime.current
    end

    context "consistent balance" do
      let(:gid) { 1101 }
      let(:book_id) { BOOKS[:merchant_balance] }
      let(:entries) { Entry.where(book_id:, gid:).order(:timestamp) }

      before do
        PayBoleto.new(payment_id: 101, merchant_id: gid, amount: 100, fee: 0).call
        PayBoleto.new(payment_id: 102, merchant_id: gid, amount: 100, fee: 0).call
        PayBoleto.new(payment_id: 103, merchant_id: gid, amount: 100, fee: 0).call
      end

      it "has consistent balance" do
        expect(described_class.ending_balance_consistent?(book_id:, gid:)).to be_truthy
      end
    end

    context "inconsistent balance" do
      let(:gid) { 1101 }
      let(:book_id) { BOOKS[:merchant_balance] }
      let(:entries) { Entry.where(book_id:, gid:).order(:timestamp) }

      before do
        PayBoleto.new(payment_id: 101, merchant_id: gid, amount: 100, fee: 0).call
        PayBoleto.new(payment_id: 102, merchant_id: gid, amount: 100, fee: 0).call
        PayBoleto.new(payment_id: 103, merchant_id: gid, amount: 100, fee: 0).call
        entries.second.update_column(:amount, 50)
        entries.second.update_column(:ending_balance, 9999)
      end

      it "has amount and ending balances inconsistent" do
        expect(described_class.amount_consistent?).to be_falsey
        expect(described_class.ending_balance_consistent?(book_id:, gid:)).to be_falsey
      end

      describe ".rebuild_balances" do
        it "raises error if not confirmed" do
          expect{ described_class.rebuild_balances }.to raise_error(ArgumentError)
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
        it "fixes ending balances" do
          described_class.rebuild_book_gid_balance(book_id, gid)
          expect(described_class.ending_balance_consistent?(book_id:, gid:)).to be_truthy
        end

        it "does not fix previously spoiled amounts" do
          expect(described_class.amount_consistent?).to be_falsey
        end
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
