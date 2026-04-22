require "rails_helper"

# Transactional fixtures are disabled for this example group because the test spawns
# worker threads that need their own DB connections and need to see each other's
# committed data. We clean up manually via Stern::Repair.clear.
module Stern
  RSpec.describe "Concurrent ledger writes", type: :model do
    self.use_transactional_tests = false

    let(:book_id) { ::Stern.chart.book_code(:merchant_balance) }
    let(:gid) { 424_242 }
    let(:pair_code) { ::Stern.chart.entry_pair_codes.values.first }
    # `let` (lazy) rather than `let!` so the record is created after `before` clears.
    let(:operation) { Operation.create!(name: "race_test_op", params: {}) }

    before { Repair.clear }
    after { Repair.clear }

    def seed_prior(amount:)
      seed_pair = EntryPair.create!(code: pair_code, uid: 1, amount:, operation_id: operation.id)
      Entry.create!(book_id:, gid:, entry_pair_id: seed_pair.id, amount:)
    end

    # Mimics what BaseOperation#call does: for each thread, open a transaction,
    # take the same table locks BaseOperation#lock_tables takes, then insert.
    # A small sleep forces interleave so the bug manifests on buggy lock modes.
    def run_concurrent_inserts(n:, amount:)
      threads = n.times.map do |i|
        Thread.new do
          ApplicationRecord.connection_pool.with_connection do
            ApplicationRecord.transaction do
              ApplicationRecord.lock_table(table: EntryPair.table_name)
              ApplicationRecord.lock_table(table: Entry.table_name)
              sleep 0.05

              pair = EntryPair.create!(
                code: pair_code, uid: 2000 + i, amount:, operation_id: operation.id,
              )
              Entry.create!(book_id:, gid:, entry_pair_id: pair.id, amount:)
            end
          ensure
            ApplicationRecord.connection_pool.release_connection
          end
        end
      end
      threads.each(&:join)
    end

    it "keeps Doctor.ending_balance_consistent? true after two concurrent inserts" do
      seed_prior(amount: 100)
      run_concurrent_inserts(n: 2, amount: 50)

      expect(Doctor.ending_balance_consistent?(book_id:, gid:)).to be(true)
    end

    it "produces distinct ending_balances (100, 150, 200) for two concurrent amount=50 inserts" do
      seed_prior(amount: 100)
      run_concurrent_inserts(n: 2, amount: 50)

      ending_balances = Entry.where(book_id:, gid:).order(:timestamp, :id).pluck(:ending_balance)
      # Under the buggy ACCESS SHARE lock, the last two values would both be 150.
      expect(ending_balances).to eq([ 100, 150, 200 ])
    end

    it "stays consistent with four concurrent writers" do
      seed_prior(amount: 100)
      run_concurrent_inserts(n: 4, amount: 25)

      expect(Doctor.ending_balance_consistent?(book_id:, gid:)).to be(true)
      expect(Entry.where(book_id:, gid:).sum(:amount)).to eq(200)
      expect(Entry.where(book_id:, gid:).order(:timestamp, :id).last.ending_balance).to eq(200)
    end
  end
end
