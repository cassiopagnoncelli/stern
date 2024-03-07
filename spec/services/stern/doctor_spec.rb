require "rails_helper"

module Stern
  RSpec.describe Doctor, type: :model do
    def uid
      Integer(rand * 1e5)
    end

    def ts
      DateTime.current
    end

    context "when consistent balance" do
      let(:gid) { 1101 }
      let(:book_id) { BOOKS[:merchant_balance] }
      let(:entries) { Entry.where(book_id:, gid:).order(:timestamp) }

      before do
        PayBoleto.new(payment_id: 101, merchant_id: gid, amount: 100, fee: 0).call
        PayBoleto.new(payment_id: 102, merchant_id: gid, amount: 100, fee: 0).call
        PayBoleto.new(payment_id: 103, merchant_id: gid, amount: 100, fee: 0).call
      end

      it "has consistent balance" do
        expect(described_class).to be_ending_balance_consistent(book_id:, gid:)
      end
    end

    context "when inconsistent balance" do
      let(:gid) { 1101 }
      let(:book_id) { BOOKS[:merchant_balance] }
      let(:entries) { Entry.where(book_id:, gid:).order(:timestamp) }

      before do
        PayBoleto.new(payment_id: 101, merchant_id: gid, amount: 100, fee: 0).call
        PayBoleto.new(payment_id: 102, merchant_id: gid, amount: 100, fee: 0).call
        PayBoleto.new(payment_id: 103, merchant_id: gid, amount: 100, fee: 0).call

        # Using update_column to circumvent validations.
        # rubocop:disable Rails/SkipsModelValidations
        entries.second.update_column(:amount, 50)
        entries.second.update_column(:ending_balance, 9999)
        # rubocop:enable Rails/SkipsModelValidations
      end

      it "has amount and ending balances inconsistent" do
        expect(described_class).not_to be_amount_consistent
        expect(described_class).not_to be_ending_balance_consistent(book_id:, gid:)
      end

      describe ".rebuild_balances" do
        it "raises error if not confirmed" do
          expect { described_class.rebuild_balances }.to raise_error(ArgumentError)
        end

        it "rebuilds if confirmed" do
          allow(described_class).to receive(:rebuild_gid_balance)
          expect { described_class.rebuild_balances(confirm: true) }.not_to raise_error
        end
      end

      describe ".rebuild_gid_balance" do
        it "rebuilds based on gid" do
          allow(described_class).to receive(:rebuild_book_gid_balance)
          described_class.rebuild_gid_balance(1)          
          expect(described_class).to have_received(:rebuild_book_gid_balance).with(anything, 1).at_least(:once)
        end
      end

      describe ".rebuild_book_gid_balance" do
        it "fixes ending balances" do
          described_class.rebuild_book_gid_balance(book_id, gid)
          expect(described_class).to be_ending_balance_consistent(book_id:, gid:)
        end

        it "does not fix previously spoiled amounts" do
          expect(described_class).not_to be_amount_consistent
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
