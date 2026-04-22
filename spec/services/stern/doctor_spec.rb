require "rails_helper"

module Stern
  RSpec.describe Doctor, type: :model do
    let(:gid) { 1101 }
    let(:book_id) { ::Stern.chart.book_code(:merchant_balance) }
    let(:currency) { ::Stern.cur("BRL") }
    let(:entries) { Entry.where(book_id:, gid:, currency:).order(:timestamp) }
    let(:operation) { create(:operation) }

    def seed_entries(count: 3, amount: 100)
      count.times do |i|
        EntryPair.add_merchant_balance(i + 1, gid, amount, currency, operation_id: operation.id)
      end
    end

    context "when consistent balance" do
      before { seed_entries }

      it "has consistent balance" do
        expect(described_class).to be_ending_balance_consistent(book_id:, gid:, currency:)
      end

      it "has amount consistency" do
        expect(described_class).to be_amount_consistent
      end
    end

    context "when inconsistent balance" do
      before do
        seed_entries
        # Using update_column to circumvent validations — required because the records
        # are intentionally being corrupted to test the audit path.
        # rubocop:disable Rails/SkipsModelValidations
        entries.second.update_column(:amount, 50)
        entries.second.update_column(:ending_balance, 9999)
        # rubocop:enable Rails/SkipsModelValidations
      end

      it "has amount and ending balances inconsistent" do
        expect(described_class).not_to be_amount_consistent
        expect(described_class).not_to be_ending_balance_consistent(book_id:, gid:, currency:)
      end
    end

    describe ".ending_balances_inconsistencies_across_books" do
      before { seed_entries }

      it "returns an array of inconsistent entry ids (empty when consistent)" do
        expect(described_class.ending_balances_inconsistencies_across_books(gid:, currency:)).to eq([])
      end
    end
  end
end
