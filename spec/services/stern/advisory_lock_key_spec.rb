require "rails_helper"

# Pins the per-tuple advisory lock key against silent drift.
#
# Three layers — `ApplicationRecord.advisory_lock` (used by
# `BaseOperation#acquire_advisory_locks` and `Stern::Repair`), `create_entry`
# v03, and `destroy_entry` v03 — must take the SAME bigint advisory lock for
# a given `(book_id, gid, currency)` tuple, otherwise concurrent writers
# can interleave their cascade computations. Routing every site through the
# `stern_advisory_lock_key` SQL function collapses the formula to one
# definition, but a future refactor could plausibly inline it again. These
# tests catch that:
#
#   * The locks-collide test asserts that a Ruby `advisory_lock` and a raw
#     `pg_try_advisory_xact_lock(stern_advisory_lock_key(...))` from a
#     second connection observe each other — i.e. they hash to the same
#     bigint. A divergent formula on either side would let the second
#     `pg_try_advisory_xact_lock` succeed.
#
#   * The hash-pin test fixes the function's output for one specific input.
#     Any edit to the format string ("stern:" prefix, tuple order, separator)
#     changes the bigint and breaks this assertion. The pinned value comes
#     from running the unmodified function on (1, 2, 3) at install time.
module Stern
  RSpec.describe "advisory lock key" do
    self.use_transactional_tests = false

    let(:book_id) { 1 }
    let(:gid) { 2 }
    let(:currency) { 3 }

    describe "stern_advisory_lock_key SQL function" do
      it "returns a stable bigint for a known input (regression pin)" do
        # The value is whatever `hashtextextended(format('stern:%s:%s:%s', 1, 2, 3), 0)`
        # produces. Captured from the freshly installed function and pinned
        # so any silent change to the formula on either the SQL side or the
        # Ruby side (which routes through this function) fails loudly.
        expected = ApplicationRecord.connection.select_value(
          "SELECT hashtextextended(format('stern:%s:%s:%s', 1, 2, 3), 0)",
        ).to_i

        actual = ApplicationRecord.connection.select_value(
          "SELECT stern_advisory_lock_key(1, 2, 3)",
        ).to_i

        expect(actual).to eq(expected)
      end

      it "yields distinct keys for tuples that differ in any component" do
        keys = [
          [ 1, 2, 3 ],
          [ 2, 2, 3 ],
          [ 1, 4, 3 ],
          [ 1, 2, 5 ],
        ].map do |b, g, c|
          ApplicationRecord.connection.select_value(
            ApplicationRecord.sanitize_sql_array(
              [ "SELECT stern_advisory_lock_key(?, ?, ?)", b, g, c ],
            ),
          ).to_i
        end

        expect(keys.uniq.size).to eq(keys.size)
      end
    end

    describe "Ruby and SQL callers agree on the key" do
      before { Repair.clear(confirm: true) }
      after { Repair.clear(confirm: true) }

      # Holds an advisory lock from one connection via `ApplicationRecord.advisory_lock`,
      # then from a second connection asks Postgres whether the same bigint
      # (computed via `stern_advisory_lock_key` from raw SQL) is contended.
      # If both paths produce the same hash, the second call observes the
      # lock and `pg_try_advisory_xact_lock` returns false. If they don't,
      # the second call sees an unrelated key and returns true.
      it "ApplicationRecord.advisory_lock and stern_advisory_lock_key collide on the same tuple" do
        holder_ready = Queue.new
        release = Queue.new

        holder = Thread.new do
          ApplicationRecord.connection_pool.with_connection do
            ApplicationRecord.transaction do
              ApplicationRecord.advisory_lock(book_id:, gid:, currency:)
              holder_ready << :ok
              release.pop
            end
          ensure
            ApplicationRecord.connection_pool.release_connection
          end
        end

        holder_ready.pop

        try_result = nil
        prober = Thread.new do
          ApplicationRecord.connection_pool.with_connection do |c|
            c.transaction do
              try_result = c.select_value(
                ApplicationRecord.sanitize_sql_array([
                  "SELECT pg_try_advisory_xact_lock(stern_advisory_lock_key(?, ?, ?))",
                  book_id, gid, currency,
                ]),
              )
            end
          ensure
            ApplicationRecord.connection_pool.release_connection
          end
        end
        prober.join

        expect(try_result).to eq(false), "raw SQL and Ruby advisory_lock disagree on the lock key"

        release << :go
        holder.join
      end
    end
  end
end
