require "rails_helper"

module Stern
  RSpec.describe Doctor, type: :model do
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

    context "when consistent balance" do
      before { seed_entries }

      it "has consistent balance" do
        expect(described_class).to be_ending_balance_consistent(book_id:, gid:, currency:)
      end

      it "has amount consistency" do
        expect(described_class).to be_amount_consistent
      end

      it "exposes nil detail when the cascade is intact" do
        expect(described_class.first_ending_balance_inconsistency(book_id:, gid:, currency:)).to be_nil
      end

      it "exposes nil detail when the global amount sums to zero" do
        expect(described_class.amount_inconsistency).to be_nil
      end

      it "first_inconsistency returns nil when both invariants hold" do
        expect(described_class.first_inconsistency).to be_nil
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

      it "first_ending_balance_inconsistency returns the offending row's detail" do
        detail = described_class.first_ending_balance_inconsistency(book_id:, gid:, currency:)

        expect(detail).to include(
          entry_id: entries.second.id,
          amount: 50,
          actual_ending_balance: 9999,
          expected_ending_balance: 100 + 50,
        )
        expect(detail[:timestamp]).to eq(entries.second.timestamp)
      end

      it "amount_inconsistency reports the non-zero sum" do
        # Original three entry-pairs sum to zero; corrupting one Entry's amount
        # from 100 → 50 leaves the global sum at -50.
        expect(described_class.amount_inconsistency).to eq(sum: -50)
      end

      it "first_inconsistency reports the amount-sum break first" do
        expect(described_class.first_inconsistency).to eq(kind: :amount_sum, sum: -50)
      end
    end

    context "when only the ending-balance cascade is broken" do
      before do
        seed_entries
        # Corrupt the cascade without touching `amount`, so the global sum
        # invariant still holds and `first_inconsistency` falls through to
        # the per-tuple walk.
        # rubocop:disable Rails/SkipsModelValidations
        entries.second.update_column(:ending_balance, 9999)
        # rubocop:enable Rails/SkipsModelValidations
      end

      it "first_inconsistency reports the ending-balance break with tuple context" do
        detail = described_class.first_inconsistency

        expect(detail).to include(
          kind: :ending_balance,
          book_id:,
          gid:,
          currency:,
          entry_id: entries.second.id,
          actual_ending_balance: 9999,
        )
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
