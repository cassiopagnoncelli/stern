require "rails_helper"

# Ensures `Stern::Repair.rebuild_*` serializes against in-flight operations on
# the same (book, gid, currency) tuple, by holding the same advisory lock that
# BaseOperation#call and create_entry v03 use. Transactional fixtures are
# disabled so the holder thread's lock is actually transaction-scoped in the
# host connection, not rolled back by the test transaction.
module Stern
  RSpec.describe "Repair concurrency", type: :model do
    self.use_transactional_tests = false

    let(:gid) { 901_001 }
    let(:currency) { ::Stern.cur("BRL") }
    let(:book_id) { ::Stern.chart.book_code(:merchant_balance) }

    before { Repair.clear }
    after { Repair.clear }

    # SQL fragment that matches the key `BaseOperation#acquire_advisory_locks` and
    # `create_entry` v03 use for this tuple. If Repair acquires the same key, a
    # concurrent holder of it will block Repair.
    def lock_key_sql
      "hashtextextended(format('stern:%s:%s:%s', #{book_id}, #{gid}, #{currency}), 0)"
    end

    def seed_one_entry
      op = Operation.create!(name: "repair_concurrency_seed", params: {})
      EntryPair.add_merchant_balance(
        SecureRandom.random_number(1 << 30), gid, 100, currency, operation_id: op.id,
      )
    end

    describe ".rebuild_book_gid_balance" do
      # Prove Repair honors the (book, gid, currency) advisory lock. Thread A
      # takes the lock explicitly and holds it until signaled. Thread B calls
      # `Repair.rebuild_book_gid_balance` for the same tuple. If Repair takes
      # the same lock, Thread B must block until Thread A releases.
      it "blocks on the (book, gid, currency) advisory lock held by a concurrent writer" do
        seed_one_entry

        holder_ready = Queue.new
        release = Queue.new

        holder = Thread.new do
          ApplicationRecord.connection_pool.with_connection do |c|
            c.transaction do
              c.execute("SELECT pg_advisory_xact_lock(#{lock_key_sql})")
              holder_ready << :ok
              release.pop
            end
          ensure
            ApplicationRecord.connection_pool.release_connection
          end
        end

        holder_ready.pop
        repair_started = Time.now
        repair_finished_at = nil

        repair = Thread.new do
          ApplicationRecord.connection_pool.with_connection do
            Repair.rebuild_book_gid_balance(book_id, gid, currency)
            repair_finished_at = Time.now
          ensure
            ApplicationRecord.connection_pool.release_connection
          end
        end

        # Give the repair thread a clear chance to enter its critical section
        # and block on the lock. If it did NOT acquire the lock, it would
        # complete well within this window (the rebuild UPDATE is microseconds).
        sleep 0.20
        expect(repair.alive?).to be(true), "Repair did not block — it is not acquiring the advisory lock"

        # Release the holder; Repair should now proceed to completion.
        release << :go
        holder.join
        repair.join

        # Repair's wall time should include the blocked period.
        expect(repair_finished_at - repair_started).to be >= 0.19
      end
    end
  end
end
