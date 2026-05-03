require "rails_helper"

# STRUCTURAL INVARIANTS — the record-graph shape that BaseOperation#call and
# EntryPair.double_entry_add are *supposed* to guarantee. These specs prove the
# LedgerInvariants helpers catch deliberate violations, then confirm clean
# state passes.
#
# Each violating test uses raw SQL to sidestep the model-level write path
# (custom create!/destroy!, FK constraints, validations) — that is the bug
# class these helpers exist to catch.
module Stern
  RSpec.describe "Ledger referential integrity helpers", type: :model do
    self.use_transactional_tests = false

    let(:brl) { ::Stern.cur("BRL") }
    let(:merchant_id) { 980_001 }

    before { Repair.clear }
    after { Repair.clear }

    def seed_one_pair(gid: merchant_id, amount: 500, op_name: "invariant_seed", op_params: {})
      op = Operation.create!(name: op_name, params: op_params)
      EntryPair.add_merchant_available(
        SecureRandom.random_number(1 << 30), gid, amount, brl, operation_id: op.id,
      )
      op
    end

    describe "assert_entry_pairs_structurally_sound!" do
      it "passes on a clean ledger" do
        seed_one_pair
        expect { assert_entry_pairs_structurally_sound! }.not_to raise_error
      end

      it "catches an EntryPair with only one Entry (physical delete of one half)" do
        seed_one_pair
        victim_id = Entry.order(:id).last.id
        # Raw DELETE sidesteps Entry#destroy! (which would cascade via destroy_entry).
        Entry.connection.execute("DELETE FROM stern_entries WHERE id = #{victim_id}")

        expect { assert_entry_pairs_structurally_sound! }
          .to raise_error(RSpec::Expectations::ExpectationNotMetError, /expected 2 entries, found 1/)
      end

      it "catches two Entries that do not cancel (amounts don't sum to zero)" do
        seed_one_pair
        target = Entry.order(:id).last
        # Raw UPDATE sidesteps AppendOnly.
        Entry.connection.execute(
          "UPDATE stern_entries SET amount = amount + 1 WHERE id = #{target.id}",
        )

        expect { assert_entry_pairs_structurally_sound! }
          .to raise_error(RSpec::Expectations::ExpectationNotMetError, /amounts do not cancel/)
      end

      it "catches an Entry written to a book not declared for the pair" do
        seed_one_pair
        ep = EntryPair.order(:id).last
        # Flip the book_add side to an entirely unrelated book (not the
        # declared book_add and not the declared book_sub). The schema's
        # unique index (book_id, gid, currency, entry_pair_id) does not block
        # this — we're moving to a different book_id, not colliding with the
        # other half's book_id.
        wrong_book = ::Stern.chart.book_code(:customer_available)
        Entry.connection.execute(<<~SQL)
          UPDATE stern_entries
          SET book_id = #{wrong_book}
          WHERE entry_pair_id = #{ep.id} AND amount > 0
        SQL

        expect { assert_entry_pairs_structurally_sound! }
          .to raise_error(RSpec::Expectations::ExpectationNotMetError, /book_add side on book_id=/)
      end

      it "catches an EntryPair whose entries span different gids" do
        seed_one_pair
        target = Entry.order(:id).last
        Entry.connection.execute(
          "UPDATE stern_entries SET gid = gid + 1 WHERE id = #{target.id}",
        )

        expect { assert_entry_pairs_structurally_sound! }
          .to raise_error(RSpec::Expectations::ExpectationNotMetError, /different gids/)
      end
    end

    describe "assert_operations_integral!" do
      it "passes on a clean ledger" do
        seed_one_pair
        expect { assert_operations_integral! }.not_to raise_error
      end

      it "catches an Operation with no associated EntryPairs" do
        # An Operation without any EntryPair — impossible through the normal
        # transactional call path, but fabricate one directly to prove the
        # helper catches it.
        Operation.create!(name: "orphan", params: {})

        expect { assert_operations_integral! }
          .to raise_error(RSpec::Expectations::ExpectationNotMetError, /no associated EntryPairs/)
      end

      it "catches a ChargePix whose params.merchant_id does not match the written gid" do
        op = Operation.create!(
          name: "ChargePix",
          params: { "merchant_id" => 12_345, "charge_id" => 1, "amount" => 100, "currency" => brl },
        )
        # Seed an EntryPair on a DIFFERENT gid than params.merchant_id claims.
        EntryPair.add_charge_pix(
          SecureRandom.random_number(1 << 30), 99_999, 100, brl, operation_id: op.id,
        )

        expect { assert_operations_integral! }
          .to raise_error(RSpec::Expectations::ExpectationNotMetError, /params\.merchant_id=12345/)
      end

      it "restored clean state passes again" do
        # Restoration check (after the violation tests above, Repair.clear has run).
        seed_one_pair
        expect { assert_operations_integral! }.not_to raise_error
        expect { assert_entry_pairs_structurally_sound! }.not_to raise_error
      end
    end
  end
end
