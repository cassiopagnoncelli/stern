require "rails_helper"

# Past-timestamp cascade concurrency. Companion to spec/operations/stern/concurrency_spec.rb,
# which exercises the tail-append branch of `create_entry` (db/functions/create_entry.sql).
# This file targets the OTHER write path: `in_timestamp_utc` set, which inserts at the supplied
# timestamp and then UPDATEs every later row's `ending_balance` via a window-sum recompute.
#
# The proof is that the transaction-scoped `pg_advisory_xact_lock` taken inside `create_entry`
# (defense-in-depth, complementing `BaseOperation#acquire_advisory_locks`) serializes those
# cascade UPDATEs on a single `(book_id, gid, currency)` partition. If it didn't, two
# overlapping cascades could interleave and rewrite each other's `ending_balance` values into
# a state inconsistent with the running sum of `amount`s — exactly the invariant
# `Doctor.ending_balance_consistent?` checks.
#
# Pattern mirrors concurrency_spec.rb: transactional fixtures off, manual `Repair.clear`
# bookends, threads check out their own connections via `connection_pool.with_connection`,
# `Concurrent::AtomicFixnum` for success counters, `Queue` for failure surfaces.
module Stern
  RSpec.describe "Past-timestamp cascade concurrency", type: :model do
    self.use_transactional_tests = false

    let(:currency) { ::Stern.cur("BRL") }
    let(:merchant_id) { 920_101 }
    let(:available_book_id) { ::Stern.chart.book_code(:merchant_available) }
    let(:available0_book_id) { ::Stern.chart.book_code(:merchant_available_0) }
    let(:credit_book_id) { ::Stern.chart.book_code(:merchant_credit) }
    let(:credit0_book_id) { ::Stern.chart.book_code(:merchant_credit_0) }
    let(:base_time) { Time.current.beginning_of_minute - 1.hour }

    before { Repair.clear(confirm: true) }
    after { Repair.clear(confirm: true) }

    # Bumped pool checkout: each worker holds a connection via `with_connection`,
    # and serializing on the cascade lock can stall a thread well past AR's
    # default 5s. Same pattern as repair_concurrency_spec / 1000-thread stress.
    around do |example|
      pool = ApplicationRecord.connection_pool
      original = pool.checkout_timeout
      pool.instance_variable_set(:@checkout_timeout, 60)
      begin
        example.run
      ensure
        pool.instance_variable_set(:@checkout_timeout, original)
      end
    end

    # Each test reuses one `Operation` row across seed and contended writes. The
    # FK chain (entries -> entry_pairs -> operations) is required by the schema
    # since 6291baa; sharing a single op keeps the audit row alive even when
    # every contended write is rejected (test 3), which would otherwise leave an
    # orphan op behind.
    let(:operation) { Operation.create!(name: "concurrency_test", params: {}) }

    # Wraps a single `EntryPair.add_*` write in a transaction so a leg-2 failure
    # rolls back leg 1. Without the wrap, `EntryPair.find_or_create_by!` and the
    # first `Entry.create!` auto-commit, and a NN rejection on the second leg
    # would leak a half-written pair — ledger-invariant noise the test isn't
    # interested in. Mirrors the atomicity `BaseOperation#call` provides.
    def atomic_pair_write
      ApplicationRecord.transaction { yield }
    end

    def assert_partition_consistent!(book_id:)
      aggregate_failures "ledger invariants on book_id=#{book_id}" do
        expect(Doctor.amount_consistent?).to be(true)
        expect(Doctor.ending_balance_consistent?(book_id:, gid: merchant_id, currency:)).to be(true)
      end
    end

    describe "concurrent past-timestamp inserts at distinct timestamps" do
      # 5 baseline entries 10 minutes apart, then N threads each insert at a
      # distinct past timestamp wedged between the first two baseline entries.
      # All inserts cascade through the same 4 downstream baseline rows — the
      # scenario where overlapping cascades would corrupt each other if the
      # advisory lock weren't there.
      it "converges to a consistent ledger across all threads" do
        baseline_amounts = [ 1000, 1000, 1000, 1000, 1000 ]
        baseline_amounts.each_with_index do |amt, idx|
          EntryPair.add_merchant_available(
            SecureRandom.random_number(1 << 30), merchant_id, merchant_id, amt, currency,
            timestamp: base_time + (idx * 10).minutes,
            operation_id: operation.id,
          )
        end

        thread_count = 8
        per_thread_amount = 100
        successes = Concurrent::AtomicFixnum.new(0)
        errors = Queue.new

        # Wedge between baseline[0]=base_time and baseline[1]=base_time+10min.
        # Distinct seconds so the (book, gid, currency, timestamp) unique
        # index never trips — this test isolates the cascade race.
        timestamps = (1..thread_count).map { |n| base_time + 5.minutes + n.seconds }

        threads = timestamps.map.with_index do |ts, idx|
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              atomic_pair_write do
                EntryPair.add_merchant_available(
                  SecureRandom.random_number(1 << 30) + idx,
                  merchant_id,
                  merchant_id, per_thread_amount, currency,
                  timestamp: ts, operation_id: operation.id,
                )
              end
              successes.increment
            rescue StandardError => e
              errors << "#{e.class}: #{e.message}"
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        end
        threads.each(&:join)

        errs = []
        errs << errors.pop until errors.empty?
        expect(errs).to be_empty, "unexpected errors: #{errs.inspect}"
        expect(successes.value).to eq(thread_count)

        # Numeric closure: the final ending_balance and the physical sum agree,
        # and both equal what a sequential application would produce.
        expected_final = baseline_amounts.sum + (thread_count * per_thread_amount)
        scope = Entry.where(book_id: available_book_id, gid: merchant_id, currency:)
        expect(scope.sum(:amount)).to eq(expected_final)
        expect(scope.order(:timestamp, :id).last.ending_balance).to eq(expected_final)

        # Cascade integrity per partition. Both legs of the pair land on
        # distinct partitions (`merchant_available`, `merchant_available_0`);
        # both must be consistent.
        assert_partition_consistent!(book_id: available_book_id)
        assert_partition_consistent!(book_id: available0_book_id)

        # Strict-monotonic running sum: with all amounts of the same sign on
        # `merchant_available`, no two rows share an `ending_balance` value
        # under correct serialization.
        all_ending = scope.order(:timestamp, :id).pluck(:ending_balance)
        expect(all_ending).to eq(all_ending.uniq)
      end
    end

    describe "concurrent past-timestamp inserts at the same timestamp" do
      # The `(book_id, gid, currency, timestamp)` unique index is the
      # tiebreaker when two writers race on identical coordinates. Under the
      # advisory lock, the second writer's INSERT runs after the first commits
      # and must hit `index_stern_entries_on_bgct`; the wrapping transaction
      # rolls back its EntryPair so no leftover state survives the loss.
      it "lets exactly one thread win and rejects the rest on the unique index" do
        [ 500, 500, 500 ].each_with_index do |amt, idx|
          EntryPair.add_merchant_available(
            SecureRandom.random_number(1 << 30), merchant_id, merchant_id, amt, currency,
            timestamp: base_time + (idx * 10).minutes,
            operation_id: operation.id,
          )
        end
        collision_ts = base_time + 5.minutes

        thread_count = 4
        successes = Concurrent::AtomicFixnum.new(0)
        unique_violations = Queue.new
        unexpected = Queue.new

        threads = thread_count.times.map do |i|
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              atomic_pair_write do
                EntryPair.add_merchant_available(
                  SecureRandom.random_number(1 << 30) + i,
                  merchant_id,
                  merchant_id, 50, currency,
                  timestamp: collision_ts, operation_id: operation.id,
                )
              end
              successes.increment
            rescue ActiveRecord::RecordNotUnique => e
              unique_violations << e
            rescue StandardError => e
              unexpected << "#{e.class}: #{e.message}"
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        end
        threads.each(&:join)

        unexpected_drained = []
        unexpected_drained << unexpected.pop until unexpected.empty?
        expect(unexpected_drained).to be_empty,
          "expected only RecordNotUnique on losers, got: #{unexpected_drained.inspect}"

        expect(successes.value).to eq(1), "exactly one writer must win the unique-index race"
        expect(unique_violations.size).to eq(thread_count - 1)

        # Each loser must have failed on the bgct unique index (the timestamp
        # collision), not on bgce or some other constraint, so that what we're
        # actually catching is the past-timestamp coordinate clash this test
        # is named for.
        (thread_count - 1).times do
          err = unique_violations.pop
          expect(err.message.to_s).to match(/index_stern_entries_on_bgct/i),
            "loser raised an unexpected RecordNotUnique: #{err.message.inspect}"
        end

        # Exactly one row landed at `collision_ts` on each side of the pair,
        # and the cascade folded the new amount into both partitions.
        expect(Entry.where(book_id: available_book_id, gid: merchant_id, currency:,
                           timestamp: collision_ts).count).to eq(1)
        expect(Entry.where(book_id: available0_book_id, gid: merchant_id, currency:,
                           timestamp: collision_ts).count).to eq(1)

        assert_partition_consistent!(book_id: available_book_id)
        assert_partition_consistent!(book_id: available0_book_id)
      end
    end

    describe "non_negative book under contended past-timestamp inserts" do
      # `merchant_credit` is non_negative. Seed it positive, then leave a
      # downstream `apply_merchant_credit` row that brings the cascade close to
      # zero. Concurrent past-timestamp `apply_merchant_credit` inserts whose
      # cascade would push that downstream row below zero must ALL be rejected
      # by the post-cascade NN check in create_entry.sql — and the wrapping
      # transaction must roll back both legs of the pair so the ledger is
      # byte-for-byte unchanged from the seed.
      #
      # The race the test guards against: under a missing or wrongly-scoped
      # lock, two threads' overlapping cascade UPDATEs could leave the
      # downstream row at a value that LOOKS non-negative when each thread
      # checks it (because each thread's last UPDATE only saw its own delta),
      # while the true running sum is negative.
      it "rejects every concurrent overdraft attempt and leaves the ledger unchanged" do
        # Step 1: deposit 100 credit at base_time (merchant_credit ending = 100).
        EntryPair.add_merchant_credit(
          SecureRandom.random_number(1 << 30), merchant_id, merchant_id, 100, currency,
          timestamp: base_time, operation_id: operation.id,
        )
        # Step 2: apply 80 credit at base_time + 30.minutes
        # (merchant_credit downstream ending = 100 - 80 = 20).
        EntryPair.add_apply_merchant_credit(
          SecureRandom.random_number(1 << 30), merchant_id, merchant_id, 80, currency,
          timestamp: base_time + 30.minutes, operation_id: operation.id,
        )

        snapshot = lambda do |book_id|
          Entry.where(book_id:, gid: merchant_id, currency:)
            .order(:timestamp, :id).pluck(:id, :amount, :ending_balance, :timestamp)
        end
        credit_snapshot_before = snapshot.call(credit_book_id)
        avail_snapshot_before  = snapshot.call(available_book_id)

        # Sanity: the downstream `merchant_credit` row sits at 20, and any
        # cascade reducing it by more than 20 must trip the NN check.
        expect(credit_snapshot_before.last[2]).to eq(20)

        thread_count = 6
        violations = Concurrent::AtomicFixnum.new(0)
        unexpected_successes = Concurrent::AtomicFixnum.new(0)
        unexpected = Queue.new

        # Each thread: apply 50 credit at a distinct past timestamp wedged
        # between base_time and base_time + 30.minutes. Per-row check passes
        # at the inserted row (100 - 50 = 50, positive), but the cascade
        # rewrites the t+30m row to 20 - 50 = -30, tripping the post-cascade
        # NN check.
        timestamps = (1..thread_count).map { |n| base_time + 5.minutes + n.seconds }

        threads = timestamps.map.with_index do |ts, idx|
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              atomic_pair_write do
                EntryPair.add_apply_merchant_credit(
                  SecureRandom.random_number(1 << 30) + idx,
                  merchant_id,
                  merchant_id, 50, currency,
                  timestamp: ts, operation_id: operation.id,
                )
              end
              unexpected_successes.increment
            rescue BalanceNonNegativeViolation
              violations.increment
            rescue StandardError => e
              unexpected << "#{e.class}: #{e.message}"
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        end
        threads.each(&:join)

        unexpected_drained = []
        unexpected_drained << unexpected.pop until unexpected.empty?
        expect(unexpected_drained).to be_empty,
          "expected only BalanceNonNegativeViolation, got: #{unexpected_drained.inspect}"

        expect(unexpected_successes.value).to eq(0), "no overdraft thread should have committed"
        expect(violations.value).to eq(thread_count)

        # Ledger is byte-for-byte unchanged on every partition the rejected
        # writes would have touched (`merchant_credit` directly via cascade,
        # `merchant_available` indirectly via the pair's other leg).
        expect(snapshot.call(credit_book_id)).to eq(credit_snapshot_before)
        expect(snapshot.call(available_book_id)).to eq(avail_snapshot_before)

        assert_partition_consistent!(book_id: credit_book_id)
        assert_partition_consistent!(book_id: credit0_book_id)
        assert_partition_consistent!(book_id: available_book_id)
      end
    end
  end
end
