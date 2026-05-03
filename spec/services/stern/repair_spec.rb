require "rails_helper"

module Stern
  RSpec.describe Repair, type: :model do
    let(:gid) { 1101 }
    let(:book_id) { ::Stern.chart.book_code(:merchant_available) }
    let(:currency) { ::Stern.cur("BRL") }
    let(:entries) { Entry.where(book_id:, gid:, currency:).order(:timestamp) }
    let(:operation) { create(:operation) }

    def seed_entries(count: 3, amount: 100)
      count.times do |i|
        EntryPair.add_merchant_available(i + 1, gid, amount, currency, operation_id: operation.id)
      end
    end

    context "when balances are corrupted" do
      before do
        seed_entries
        # rubocop:disable Rails/SkipsModelValidations
        entries.second.update_column(:amount, 50)
        entries.second.update_column(:ending_balance, 9999)
        # rubocop:enable Rails/SkipsModelValidations
      end

      describe ".rebuild_balances" do
        it "raises ArgumentError when not confirmed" do
          expect { described_class.rebuild_balances }.to raise_error(ArgumentError)
        end

        it "rebuilds when confirmed" do
          allow(described_class).to receive(:rebuild_gid_balance)
          expect { described_class.rebuild_balances(confirm: true) }.not_to raise_error
        end
      end

      describe ".rebuild_gid_balance" do
        it "rebuilds every book for the given gid" do
          allow(described_class).to receive(:rebuild_book_gid_balance)
          described_class.rebuild_gid_balance(gid, currency)
          expect(described_class).to have_received(:rebuild_book_gid_balance)
            .with(anything, gid, currency).at_least(:once)
        end
      end

      describe ".rebuild_book_gid_balance" do
        it "fixes ending balances" do
          described_class.rebuild_book_gid_balance(book_id, gid, currency)
          expect(Doctor).to be_ending_balance_consistent(book_id:, gid:, currency:)
        end

        it "does not fix previously spoiled amounts" do
          described_class.rebuild_book_gid_balance(book_id, gid, currency)
          expect(Doctor).not_to be_amount_consistent
        end

        it "raises ArgumentError for a non-numeric book_id" do
          expect { described_class.rebuild_book_gid_balance("x", gid, currency) }
            .to raise_error(ArgumentError)
        end

        it "raises ArgumentError for an unknown numeric book_id" do
          expect { described_class.rebuild_book_gid_balance(0, gid, currency) }
            .to raise_error(ArgumentError)
        end

        it "raises ArgumentError for a non-numeric gid" do
          expect { described_class.rebuild_book_gid_balance(book_id, "x", currency) }
            .to raise_error(ArgumentError)
        end

        it "raises ArgumentError for a non-numeric currency" do
          expect { described_class.rebuild_book_gid_balance(book_id, gid, "x") }
            .to raise_error(ArgumentError)
        end
      end
    end

    describe ".clear" do
      before { seed_entries }

      it "wipes entries, pairs, operations, and scheduled operations" do
        described_class.clear
        expect(Entry.count).to eq(0)
        expect(EntryPair.count).to eq(0)
        expect(Operation.count).to eq(0)
        expect(ScheduledOperation.count).to eq(0)
      end

      it "raises in production environment" do
        allow(Rails.env).to receive(:production?).and_return(true)
        expect { described_class.clear }.to raise_error(StandardError, /production/)
      end
    end
  end
end
