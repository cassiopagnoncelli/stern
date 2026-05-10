require "rails_helper"

# Targets the Ruby-side translation in `Stern::Entry.create!` / `#destroy!`:
# the PL/pgSQL `non_negative` guard in `db/functions/create_entry.sql` and
# `db/functions/destroy_entry.sql` raises with `ERRCODE = '23514'` and
# `CONSTRAINT = 'stern_books_non_negative'`. Direct callers of
# `Entry.create!` / `Entry#destroy!` (i.e. anyone bypassing `BaseOperation`'s
# `runtime_check`) must still see the typed `Stern::BalanceNonNegativeViolation`,
# not the raw `ActiveRecord::StatementInvalid` wrapper. Companion to
# `non_negative_constraint_spec.rb`, which exercises the same backstop through
# `EntryPair.add_*`; this file pins the exception shape for direct dispatch
# and asserts that unrelated DB errors keep propagating untranslated.
module Stern
  RSpec.describe "Entry non_negative violation translation", type: :model do
    self.use_transactional_tests = false

    let(:currency) { ::Stern.cur("BRL") }
    let(:flagged_book_id) { ::Stern.chart.book_code(:merchant_credit) }
    let(:gid) { 980_101 }

    before { Repair.clear(confirm: true) }
    after  { Repair.clear(confirm: true) }

    def operation_for_test
      @operation_for_test ||= Operation.create!(name: "nn_translation_spec", params: {})
    end

    # Any valid pair code satisfies the FK; we never read it back. Inlined
    # rather than hoisted to a constant — `entry_cascade_spec.rb` uses the
    # same name at module scope and the two would collide on full-suite runs.
    def seed_pair!(id:, amount:, timestamp: 100.years.ago)
      EntryPair.create!(
        id:, code: :withhold_merchant_balance, uid: gid, amount:, currency:,
        timestamp:, operation_id: operation_for_test.id,
      )
    end

    def create_entry!(amount:, entry_pair_id:, timestamp: nil, book_id: flagged_book_id)
      seed_pair!(id: entry_pair_id, amount:) unless EntryPair.exists?(id: entry_pair_id)
      Entry.create!(book_id:, gid:, entry_pair_id:, amount:, currency:, timestamp:)
    end

    describe "pre-insert non_negative check" do
      it "translates the PG check_violation into BalanceNonNegativeViolation" do
        create_entry!(amount: 100, entry_pair_id: 1)

        expect { create_entry!(amount: -150, entry_pair_id: 2) }
          .to raise_error(::Stern::BalanceNonNegativeViolation)
      end

      it "preserves the PL/pgSQL context (book_id, gid, currency) in the message" do
        create_entry!(amount: 100, entry_pair_id: 11)

        expect { create_entry!(amount: -150, entry_pair_id: 12) }
          .to raise_error(::Stern::BalanceNonNegativeViolation, /book_id=#{flagged_book_id}.*gid=#{gid}.*currency=#{currency}/)
      end

      it "subclasses InsufficientFunds so coarser rescues still catch it" do
        create_entry!(amount: 50, entry_pair_id: 21)

        expect { create_entry!(amount: -75, entry_pair_id: 22) }
          .to raise_error(::Stern::InsufficientFunds)
      end

      it "commits no row when the check fires" do
        create_entry!(amount: 100, entry_pair_id: 31)
        before_count = Entry.where(book_id: flagged_book_id, gid:, currency:).count

        expect { create_entry!(amount: -150, entry_pair_id: 32) }
          .to raise_error(::Stern::BalanceNonNegativeViolation)
        expect(Entry.where(book_id: flagged_book_id, gid:, currency:).count).to eq(before_count)
      end
    end

    describe "post-cascade non_negative check (past-timestamp insert)" do
      it "translates a violation triggered by downstream rows going negative" do
        # Seed +100 at t-3h, then -80 at t-1h — partition: 100, 20.
        create_entry!(amount: 100, entry_pair_id: 41, timestamp: 3.hours.ago)
        create_entry!(amount: -80, entry_pair_id: 42, timestamp: 1.hour.ago)

        # Insert -50 at t-2h. The new row itself lands at 100 + (-50) = 50,
        # passing the pre-insert check. The cascade rewrites the t-1h row to
        # 50 + (-80) = -30, tripping the post-cascade scan.
        expect {
          create_entry!(amount: -50, entry_pair_id: 43, timestamp: 2.hours.ago)
        }.to raise_error(::Stern::BalanceNonNegativeViolation, /past-timestamp insert.*book_id=#{flagged_book_id}/)

        # Rolled back: partition unchanged, no negative rows.
        expect(Entry.where(book_id: flagged_book_id, gid:, currency:)
          .order(:timestamp).pluck(:amount, :ending_balance)).to eq([ [ 100, 100 ], [ -80, 20 ] ])
      end
    end

    describe "destroy! cascade non_negative check" do
      it "translates a violation when removing a positive entry would leave subsequent rows negative" do
        create_entry!(amount: 100, entry_pair_id: 51, timestamp: 2.hours.ago)
        create_entry!(amount: -80, entry_pair_id: 52, timestamp: 1.hour.ago)

        positive_row = Entry.find_by!(book_id: flagged_book_id, gid:, currency:, amount: 100)

        expect { positive_row.destroy! }
          .to raise_error(::Stern::BalanceNonNegativeViolation, /destroy_entry.*book_id=#{flagged_book_id}/)

        expect(Entry.where(book_id: flagged_book_id, gid:, currency:).count).to eq(2)
      end
    end

    describe "narrow rescue scope" do
      # The translator must only fire for the non_negative constraint. Any
      # other PL/pgSQL `RAISE EXCEPTION` (future timestamp, NULL inputs, the
      # uniqueness index on (book_id, gid, currency, timestamp), etc.) must
      # surface as the original `ActiveRecord::StatementInvalid` so callers
      # don't mistake an unrelated failure for a balance issue.
      it "lets the future-timestamp PL/pgSQL raise propagate untranslated" do
        expect {
          create_entry!(amount: 10, entry_pair_id: 61, timestamp: 1.hour.from_now)
        }.to raise_error(ActiveRecord::StatementInvalid) { |e|
          expect(e).not_to be_a(::Stern::BalanceNonNegativeViolation)
          expect(e.message).to match(/cannot be in the future/)
        }
      end

      it "lets the duplicate-(book,gid,currency,timestamp) raise propagate untranslated" do
        ts = 2.hours.ago
        create_entry!(amount: 50, entry_pair_id: 71, timestamp: ts)

        expect {
          create_entry!(amount: 25, entry_pair_id: 72, timestamp: ts)
        }.to raise_error(ActiveRecord::StatementInvalid) { |e|
          expect(e).not_to be_a(::Stern::BalanceNonNegativeViolation)
          expect(e.message).to match(/duplicate key/)
        }
      end
    end

    describe "permissive book is unaffected" do
      it "does not trip the translator for a book with non_negative = false" do
        permissive_book_id = ::Stern.chart.book_code(:merchant_adjusted)
        expect(Book.find(permissive_book_id).non_negative).to be(false)

        expect {
          create_entry!(amount: -200, entry_pair_id: 81, book_id: permissive_book_id)
        }.not_to raise_error
      end
    end
  end
end
