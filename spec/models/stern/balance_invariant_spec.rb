require "rails_helper"

# SACRED INVARIANTS the ledger must hold under any concurrent load:
#
#   S1. `Doctor.ending_balance_consistent?(book_id:, gid:, currency:)` is true.
#       (Each row's `ending_balance` equals the running sum up to that row.)
#   S2. `Doctor.amount_consistent?` is true (sum of all entry amounts across the
#       whole ledger is zero — double-entry balances to zero).
#   S3. The last row's `ending_balance` equals the physical sum of amounts for
#       that (book, gid, currency). (Split-brain detector — catches the user's
#       "final balance 20 but physical sum -60" race.)
#   S4. In a MONOTONIC sequence (all writes same sign, fixed magnitudes), no two
#       rows share an `ending_balance`. Duplicates would mean two writes raced
#       on the same prior read. Asserted per-test where monotonic; NOT part of
#       `assert_sacred!` because mixed-sign sequences can produce duplicates
#       legitimately (e.g. +100, -100, +100 returns to a prior balance).
#   S5. Business invariant: if a balance check is part of the operation's
#       logic, the observed balance never goes negative.
#
# This file exercises the locking primitives against adversarial concurrent
# loads and asserts S1, S2, S3 via `assert_sacred!` always; S4 in targeted
# monotonic tests; S5 in the withdraw/overdraft test.
#
# S5 here is the APP-level path: each operation pre-checks the balance and
# raises `InsufficientFunds` before writing. The DB-level backstop — a chart
# flag `non_negative: true` that pushes the check into `create_entry` so
# forgetful operations also can't corrupt the invariant — is covered in
# `spec/models/stern/non_negative_constraint_spec.rb`.
module Stern
  RSpec.describe "Balance invariants under concurrent load", type: :model do
    self.use_transactional_tests = false

    let(:brl) { ::Stern.cur("BRL") }
    let(:usd) { ::Stern.cur("USD") }
    let(:book_id) { ::Stern.chart.book_code(:merchant_balance) }
    let(:customer_book_id) { ::Stern.chart.book_code(:customer_balance) }

    before { Repair.clear }
    # Structural invariants run before Repair.clear (LIFO). Every stress test in
    # this file now validates the record-graph shape as well as the numeric
    # cascade — see spec/support/stern/ledger_invariants.rb.
    after do
      assert_entry_pairs_structurally_sound!
      assert_operations_integral!
    end
    after { Repair.clear }

    def seed_balance(gid:, currency: brl, amount:, book: :merchant_balance)
      op = Operation.create!(name: "invariant_seed", params: {})
      if book == :merchant_balance
        EntryPair.add_merchant_balance(
          SecureRandom.random_number(1 << 30), gid, amount, currency, operation_id: op.id,
        )
      elsif book == :customer_balance
        EntryPair.add_customer_balance(
          SecureRandom.random_number(1 << 30), gid, amount, currency, operation_id: op.id,
        )
      end
    end

    def assert_sacred!(gid:, currency: brl, book_id_override: nil)
      bid = book_id_override || book_id
      entries = Entry.where(book_id: bid, gid:, currency:).order(:timestamp, :id)

      # S1
      expect(Doctor.ending_balance_consistent?(book_id: bid, gid:, currency:)).to be(true),
        "Doctor flagged ending_balance inconsistent"
      # S2
      expect(Doctor.amount_consistent?).to be(true),
        "Doctor flagged amount inconsistent (sum of all amounts != 0)"
      # S3 (only when entries exist for that tuple)
      if entries.any?
        expect(entries.last.ending_balance).to eq(entries.sum(:amount)),
          "last.ending_balance (#{entries.last.ending_balance}) != physical sum (#{entries.sum(:amount)}) — split-brain"
      end
    end

    # S4 helper — asserts no two rows share an `ending_balance`. Only valid for
    # tests where the sequence of writes is monotonic in one direction or where
    # intermediate states can't return to a prior balance.
    def assert_no_duplicate_endings!(gid:, currency: brl, book_id_override: nil)
      bid = book_id_override || book_id
      all_ending = Entry.where(book_id: bid, gid:, currency:).pluck(:ending_balance)
      expect(all_ending).to eq(all_ending.uniq),
        "duplicate ending_balance values (race artifact): #{all_ending.tally.select { |_, n| n > 1 }}"
    end

    # ─────────────────────────────────────────────────────────────────────
    # S1–S4: High-contention stress test.
    # Hammers one tuple with a mix of deposits and withdraws; asserts the
    # cascade stays strictly consistent. No business check here — this is
    # purely the cascade-correctness invariant under heavy load.
    # ─────────────────────────────────────────────────────────────────────
    describe "stress: high contention on a single (book, gid, currency)" do
      it "converges to a consistent cascade under 20 concurrent mixed writes" do
        gid = 960_001
        seed_balance(gid:, amount: 10_000)

        amounts = (Array.new(10) { [ +100, -50 ].sample } + Array.new(10) { [ +250, -150, +75 ].sample }).shuffle
        expected_sum = 10_000 + amounts.sum

        op_class = Class.new(BaseOperation) do
          inputs :merchant_id, :amount, :currency
          def target_tuples
            tuples_for_pair(:merchant_balance, merchant_id, currency)
          end

          def perform(operation_id)
            ::Stern::EntryPair.add_merchant_balance(
              SecureRandom.random_number(1 << 30), merchant_id, amount, currency, operation_id:,
            )
          end
        end
        stub_const("Stern::StressOp", op_class)

        threads = amounts.map do |amt|
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              StressOp.new(merchant_id: gid, amount: amt, currency: brl).call
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        end
        threads.each(&:join)

        assert_sacred!(gid:)
        expect(Entry.where(book_id:, gid:, currency: brl).sum(:amount)).to eq(expected_sum)
      end
    end

    # ─────────────────────────────────────────────────────────────────────
    # Isolation: ops on different dimensions (currency, book, gid) do not
    # interfere. Each run concurrently; each tuple's cascade stays correct.
    # ─────────────────────────────────────────────────────────────────────
    describe "isolation across the partitioning dimensions" do
      it "USD and BRL writes on the same gid keep independent, consistent cascades" do
        gid = 961_001
        seed_balance(gid:, currency: brl, amount: 100)
        seed_balance(gid:, currency: usd, amount: 200)

        op_class = Class.new(BaseOperation) do
          inputs :merchant_id, :amount, :currency
          def target_tuples
            tuples_for_pair(:merchant_balance, merchant_id, currency)
          end

          def perform(operation_id)
            ::Stern::EntryPair.add_merchant_balance(
              SecureRandom.random_number(1 << 30), merchant_id, amount, currency, operation_id:,
            )
          end
        end
        stub_const("Stern::IsoCurrencyOp", op_class)

        threads = []
        10.times do
          threads << Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              IsoCurrencyOp.new(merchant_id: gid, amount: 10, currency: brl).call
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        end
        10.times do
          threads << Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              IsoCurrencyOp.new(merchant_id: gid, amount: 20, currency: usd).call
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        end
        threads.each(&:join)

        assert_sacred!(gid:, currency: brl)
        assert_sacred!(gid:, currency: usd)
        expect(Entry.where(book_id:, gid:, currency: brl).sum(:amount)).to eq(100 + 10 * 10)
        expect(Entry.where(book_id:, gid:, currency: usd).sum(:amount)).to eq(200 + 10 * 20)
      end

      it "merchant_balance and customer_balance writes on the same gid keep independent cascades" do
        gid = 961_002
        seed_balance(gid:, amount: 100, book: :merchant_balance)
        seed_balance(gid:, amount: 300, book: :customer_balance)

        op_class = Class.new(BaseOperation) do
          inputs :merchant_id, :amount, :currency, :book_name
          def target_tuples
            tuples_for_pair(book_name.to_sym, merchant_id, currency)
          end

          def perform(operation_id)
            if book_name == "merchant_balance"
              ::Stern::EntryPair.add_merchant_balance(
                SecureRandom.random_number(1 << 30), merchant_id, amount, currency, operation_id:,
              )
            else
              ::Stern::EntryPair.add_customer_balance(
                SecureRandom.random_number(1 << 30), merchant_id, amount, currency, operation_id:,
              )
            end
          end
        end
        stub_const("Stern::IsoBookOp", op_class)

        threads = []
        8.times do |i|
          book = i.even? ? "merchant_balance" : "customer_balance"
          threads << Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              IsoBookOp.new(merchant_id: gid, amount: 5, currency: brl, book_name: book).call
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        end
        threads.each(&:join)

        assert_sacred!(gid:, currency: brl)
        assert_sacred!(gid:, currency: brl, book_id_override: customer_book_id)
        expect(Entry.where(book_id:, gid:, currency: brl).sum(:amount)).to eq(100 + 4 * 5)
        expect(Entry.where(book_id: customer_book_id, gid:, currency: brl).sum(:amount)).to eq(300 + 4 * 5)
      end
    end

    # ─────────────────────────────────────────────────────────────────────
    # S5: Business invariant. A balance-check-then-withdraw operation under
    # heavy contention must never let the balance go negative.
    # ─────────────────────────────────────────────────────────────────────
    describe "S5: balance never goes negative under contended withdraws" do
      it "N concurrent withdraws each of amount=100 against seed=250 cannot overdraw" do
        gid = 962_001
        seed_balance(gid:, amount: 250)

        withdraw_class = Class.new(BaseOperation) do
          inputs :merchant_id, :amount, :currency
          def target_tuples
            tuples_for_pair(:merchant_balance, merchant_id, currency)
          end

          def perform(operation_id)
            balance = ::Stern.balance(merchant_id, :merchant_balance, currency)
            raise ::Stern::InsufficientFunds if balance < amount

            ::Stern::EntryPair.add_merchant_balance(
              SecureRandom.random_number(1 << 30), merchant_id, -amount, currency, operation_id:,
            )
          end
        end
        stub_const("Stern::OverdraftGuard", withdraw_class)

        outcomes = Queue.new
        threads = 6.times.map do
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              OverdraftGuard.new(merchant_id: gid, amount: 100, currency: brl).call
              outcomes << :ok
            rescue InsufficientFunds
              outcomes << :insufficient
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        end
        threads.each(&:join)

        results = []
        results << outcomes.pop until outcomes.empty?

        # Exactly 2 succeeded (250 - 100 - 100 = 50 < 100 < 250).
        expect(results.count(:ok)).to eq(2)
        expect(results.count(:insufficient)).to eq(4)
        # Final balance is 50, never negative.
        expect(::Stern.balance(gid, :merchant_balance, brl)).to eq(50)
        assert_sacred!(gid:)
        # Monotonic sequence (+seed, -100, -100) — S4 is legitimately required here.
        assert_no_duplicate_endings!(gid:)
      end
    end

    # ─────────────────────────────────────────────────────────────────────
    # Cascade correctness: inserts with explicit past timestamps trigger a
    # cascade update of subsequent rows. Two concurrent past-timestamp
    # inserts on the same tuple must serialize and produce consistent cascades.
    # ─────────────────────────────────────────────────────────────────────
    describe "past-timestamp inserts (cascade contention)" do
      it "two concurrent past-timestamp inserts yield a consistent cascade" do
        gid = 963_001
        # Seed with three entries at t-30s, t-20s, t-10s so we have a cascade tail.
        base_op = Operation.create!(name: "past_seed", params: {})
        [ 30, 20, 10 ].each_with_index do |seconds_ago, i|
          EntryPair.add_merchant_balance(
            SecureRandom.random_number(1 << 30), gid, 100, brl,
            timestamp: seconds_ago.seconds.ago, operation_id: base_op.id,
          )
        end

        # Concurrently insert two past-timestamped entries at t-25s and t-15s.
        threads = [
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              op = Operation.create!(name: "past_a", params: {})
              EntryPair.add_merchant_balance(
                SecureRandom.random_number(1 << 30), gid, 50, brl,
                timestamp: 25.seconds.ago, operation_id: op.id,
              )
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end,
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              op = Operation.create!(name: "past_b", params: {})
              EntryPair.add_merchant_balance(
                SecureRandom.random_number(1 << 30), gid, 75, brl,
                timestamp: 15.seconds.ago, operation_id: op.id,
              )
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        ]
        threads.each(&:join)

        assert_sacred!(gid:)
        expect(Entry.where(book_id:, gid:, currency: brl).sum(:amount)).to eq(100 * 3 + 50 + 75)
      end
    end

    # ─────────────────────────────────────────────────────────────────────
    # log_operation failures (e.g. idem_key unique violation) must release
    # the advisory lock so subsequent ops on the same tuple aren't stuck.
    # ─────────────────────────────────────────────────────────────────────
    # ─────────────────────────────────────────────────────────────────────
    # NEVER-NEGATIVE — The business invariant that matters most: accounts
    # marked as "cannot go negative" (merchant/customer balances in real
    # money) must NEVER reach a negative state, at any row in the cascade,
    # regardless of how adversarially the workload is constructed.
    # ─────────────────────────────────────────────────────────────────────
    describe "never-negative: no entry ever stored with ending_balance < 0" do
      # Under the advisory lock + business check, no entry on the merchant's
      # real balance should EVER have a negative ending_balance — not just the
      # last row, but any row in the cascade. We verify by inspecting every
      # row post-storm.
      def no_row_negative!(gid:, currency: brl)
        negatives = Entry.where(book_id:, gid:, currency:)
          .where("ending_balance < 0").pluck(:id, :amount, :ending_balance, :timestamp)
        expect(negatives).to eq([]),
          "found negative ending_balance rows (should never happen): #{negatives.inspect}"
      end

      it "varied-amount withdraws against seed 100 never produce a negative ending_balance" do
        gid = 968_001
        seed_balance(gid:, amount: 100)

        varied_withdraw = Class.new(BaseOperation) do
          inputs :merchant_id, :uid, :amount, :currency
          def target_tuples
            tuples_for_pair(:merchant_balance, merchant_id, currency)
          end

          def perform(operation_id)
            balance = ::Stern.balance(merchant_id, :merchant_balance, currency)
            raise ::Stern::InsufficientFunds if balance < amount

            ::Stern::EntryPair.add_merchant_balance(
              uid, merchant_id, -amount, currency, operation_id:,
            )
          end
        end
        stub_const("Stern::VariedWithdraw", varied_withdraw)

        # 40 attempts with mixed sizes: 10×1, 10×5, 10×20, 10×50. Expected
        # funded subset: dependent on scheduling, but TOTAL funded must not
        # exceed 100, and NO row can go negative.
        amounts = [ Array.new(10, 1), Array.new(10, 5), Array.new(10, 20), Array.new(10, 50) ].flatten.shuffle
        outcomes = Queue.new

        threads = amounts.each_with_index.map do |amt, i|
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              VariedWithdraw.new(merchant_id: gid, uid: 60_000 + i, amount: amt, currency: brl).call
              outcomes << [ :ok, amt ]
            rescue InsufficientFunds
              outcomes << [ :rejected, amt ]
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        end
        threads.each(&:join)

        results = []
        results << outcomes.pop until outcomes.empty?

        funded_sum = results.select { |r, _| r == :ok }.sum { |_, amt| amt }
        expect(funded_sum).to be <= 100
        expect(::Stern.balance(gid, :merchant_balance, brl)).to eq(100 - funded_sum)
        expect(::Stern.balance(gid, :merchant_balance, brl)).to be >= 0

        # The CRITICAL assertion: no row in the cascade is negative.
        no_row_negative!(gid:)
        assert_sacred!(gid:)
      end

      it "at-boundary: exact-balance withdraws — only one of N succeeds" do
        gid = 968_002
        seed_balance(gid:, amount: 100)

        exact_withdraw = Class.new(BaseOperation) do
          inputs :merchant_id, :uid, :currency
          def target_tuples
            tuples_for_pair(:merchant_balance, merchant_id, currency)
          end

          def perform(operation_id)
            balance = ::Stern.balance(merchant_id, :merchant_balance, currency)
            raise ::Stern::InsufficientFunds if balance < 100

            ::Stern::EntryPair.add_merchant_balance(
              uid, merchant_id, -100, currency, operation_id:,
            )
          end
        end
        stub_const("Stern::ExactWithdraw", exact_withdraw)

        # 20 threads all try to withdraw the entire 100. Exactly one can.
        outcomes = Queue.new
        threads = 20.times.map do |i|
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              ExactWithdraw.new(merchant_id: gid, uid: 70_000 + i, currency: brl).call
              outcomes << :ok
            rescue InsufficientFunds
              outcomes << :insufficient
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        end
        threads.each(&:join)

        results = []
        results << outcomes.pop until outcomes.empty?

        expect(results.count(:ok)).to eq(1)
        expect(results.count(:insufficient)).to eq(19)
        expect(::Stern.balance(gid, :merchant_balance, brl)).to eq(0)
        no_row_negative!(gid:)
        assert_sacred!(gid:)
      end

      it "sustained rolling-balance: mixed deposits and withdraws never dip < 0 mid-cascade" do
        gid = 968_003
        seed_balance(gid:, amount: 50)

        rolling_op = Class.new(BaseOperation) do
          inputs :merchant_id, :uid, :amount, :currency
          def target_tuples
            tuples_for_pair(:merchant_balance, merchant_id, currency)
          end

          def perform(operation_id)
            # Always check before any signed write. Positive = deposit (no check needed).
            if amount < 0
              balance = ::Stern.balance(merchant_id, :merchant_balance, currency)
              raise ::Stern::InsufficientFunds if balance + amount < 0
            end

            ::Stern::EntryPair.add_merchant_balance(
              uid, merchant_id, amount, currency, operation_id:,
            )
          end
        end
        stub_const("Stern::RollingOp", rolling_op)

        # Interleave 20 deposits of 10 and 30 withdraws of 10. Expected net
        # change: +200 - 300 = -100 ⇒ would overdraw by 50 without checks.
        # With checks, some withdraws are rejected and final balance ≥ 0.
        amounts = (Array.new(20, +10) + Array.new(30, -10)).shuffle
        threads = amounts.each_with_index.map do |amt, i|
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              RollingOp.new(merchant_id: gid, uid: 80_000 + i, amount: amt, currency: brl).call
            rescue InsufficientFunds
              nil
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        end
        threads.each(&:join)

        # Final balance must be non-negative.
        expect(::Stern.balance(gid, :merchant_balance, brl)).to be >= 0
        # No row in the cascade is negative.
        no_row_negative!(gid:)
        assert_sacred!(gid:)
      end
    end

    # ─────────────────────────────────────────────────────────────────────
    # READER CONSISTENCY — readers during writes must see a point-in-time
    # committed view. A reader never observes a half-applied cascade.
    # ─────────────────────────────────────────────────────────────────────
    describe "reader consistency during writes" do
      it "BalanceQuery during a heavy write storm always returns a value consistent with its own snapshot" do
        gid = 969_001
        seed_balance(gid:, amount: 10_000)

        writer_op = Class.new(BaseOperation) do
          inputs :merchant_id, :uid, :currency
          def target_tuples
            tuples_for_pair(:merchant_balance, merchant_id, currency)
          end

          def perform(operation_id)
            ::Stern::EntryPair.add_merchant_balance(
              uid, merchant_id, 7, currency, operation_id:,
            )
          end
        end
        stub_const("Stern::ReaderTestWriter", writer_op)

        n_writes = 100
        writer_threads = n_writes.times.map do |i|
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              ReaderTestWriter.new(merchant_id: gid, uid: 90_000 + i, currency: brl).call
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        end

        # While writers run, readers sample the balance repeatedly. Each
        # reading must be a valid intermediate state: 10000 + 7*k for some
        # 0 ≤ k ≤ n_writes. A stale/corrupted read would fall outside this set.
        reader_samples = []
        reader_thread = Thread.new do
          loop do
            break if writer_threads.none?(&:alive?)

            ApplicationRecord.connection_pool.with_connection do
              reader_samples << ::Stern.balance(gid, :merchant_balance, brl)
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
            sleep 0.003
          end
        end

        writer_threads.each(&:join)
        reader_thread.join

        valid_set = (0..n_writes).map { |k| 10_000 + 7 * k }.to_set
        invalid = reader_samples.reject { |s| valid_set.include?(s) }
        expect(invalid).to eq([]),
          "reader observed invalid intermediate balance(s): #{invalid.uniq.first(5)}"

        expect(::Stern.balance(gid, :merchant_balance, brl)).to eq(10_000 + 7 * n_writes)
        assert_sacred!(gid:)
      end
    end

    # ─────────────────────────────────────────────────────────────────────
    # EXTREME CONTENTION — the test the user explicitly asked for.
    # 1000 threads competing on ONE balance, each doing a full read-then-write:
    #   - observe balance
    #   - deposit +1
    # Correct serialization means every thread observes a distinct balance
    # from 0..999 exactly once, every thread gets a distinct microsecond
    # timestamp, the cascade stays strictly monotonic, and the final sum is 1000.
    # Any race artifact — duplicate reads, duplicate timestamps, duplicate
    # ending_balance, lost writes — shows up as a concrete assertion failure.
    # ─────────────────────────────────────────────────────────────────────
    describe "extreme contention: 1000 threads on a single balance" do
      # Bump pool checkout_timeout so pool-queue waits don't trip the 5s default
      # under a long serialized run (the lock forces strict sequence of ops).
      around do |example|
        pool = ApplicationRecord.connection_pool
        original = pool.checkout_timeout
        pool.instance_variable_set(:@checkout_timeout, 120)
        begin
          example.run
        ensure
          pool.instance_variable_set(:@checkout_timeout, original)
        end
      end

      it "every thread observes a unique balance in [0, N) and the cascade is strictly monotonic" do
        gid = 965_001
        n = 1000

        race_op_class = Class.new(BaseOperation) do
          attr_reader :observed_balance

          inputs :merchant_id, :uid, :currency

          def target_tuples
            tuples_for_pair(:merchant_balance, merchant_id, currency)
          end

          def perform(_operation_id)
            @observed_balance = ::Stern.balance(merchant_id, :merchant_balance, currency)
            ::Stern::EntryPair.add_merchant_balance(
              uid, merchant_id, 1, currency, operation_id: operation.id,
            )
          end
        end
        stub_const("Stern::StressRaceOp", race_op_class)

        observations = Queue.new
        errors = Queue.new

        t0 = Time.now
        threads = n.times.map do |i|
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              op = StressRaceOp.new(merchant_id: gid, uid: i + 1, currency: brl)
              op.call
              observations << op.observed_balance
            rescue => e
              errors << [ e.class.name, e.message ]
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        end
        threads.each(&:join)
        wall = Time.now - t0
        # Useful perf signal; harmless noise if you don't read it.
        warn "[stress 1000-thread] wall=#{wall.round(2)}s throughput=#{(n / wall).round} ops/s"

        error_list = []
        error_list << errors.pop until errors.empty?
        expect(error_list).to eq([]), "errors during stress: #{error_list.first(3).inspect} …"

        observed = []
        observed << observations.pop until observations.empty?

        # The STRONGEST invariant: every thread's read-under-lock saw a distinct
        # balance. If any two threads read the same prior (the user's original
        # race), this assertion fails loudly.
        expect(observed.sort).to eq((0...n).to_a),
          "observed balances must be exactly [0, 1, ..., #{n - 1}]; got #{observed.tally.select { |_, c| c > 1 }}"

        entries = Entry.where(book_id:, gid:, currency: brl).order(:timestamp, :id)
        expect(entries.count).to eq(n)
        expect(entries.sum(:amount)).to eq(n)
        # S-timestamp: no duplicate timestamps across 1000 serialized inserts.
        expect(entries.pluck(:timestamp).uniq.size).to eq(n),
          "found duplicate timestamps (expected n=#{n} unique microsecond-precision timestamps)"
        # Cascade is strictly monotonic 1..n.
        expect(entries.pluck(:ending_balance)).to eq((1..n).to_a)
        assert_sacred!(gid:)
        assert_no_duplicate_endings!(gid:)
      end

      it "1000 threads trying to overdraw a limited balance: exactly funded count succeeds" do
        gid = 965_002
        seed_amount = 500 # affords exactly 500 withdraws of 1
        seed_balance(gid:, amount: seed_amount)
        n = 1000

        overdraft_op = Class.new(BaseOperation) do
          inputs :merchant_id, :uid, :currency
          def target_tuples
            tuples_for_pair(:merchant_balance, merchant_id, currency)
          end

          def perform(operation_id)
            balance = ::Stern.balance(merchant_id, :merchant_balance, currency)
            raise ::Stern::InsufficientFunds if balance < 1

            ::Stern::EntryPair.add_merchant_balance(
              uid, merchant_id, -1, currency, operation_id:,
            )
          end
        end
        stub_const("Stern::StressOverdraft", overdraft_op)

        outcomes = Queue.new
        threads = n.times.map do |i|
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              StressOverdraft.new(merchant_id: gid, uid: 10_000 + i, currency: brl).call
              outcomes << :ok
            rescue InsufficientFunds
              outcomes << :insufficient
            rescue => e
              outcomes << [ :error, e.class.name, e.message ]
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        end
        threads.each(&:join)

        results = []
        results << outcomes.pop until outcomes.empty?

        expect(results.count(:ok)).to eq(seed_amount)
        expect(results.count(:insufficient)).to eq(n - seed_amount)
        expect(results.count { |r| r.is_a?(Array) && r.first == :error }).to eq(0)

        # Balance hits exactly 0 — never a single cent negative.
        expect(::Stern.balance(gid, :merchant_balance, brl)).to eq(0)
        assert_sacred!(gid:)
        assert_no_duplicate_endings!(gid:) # monotonic withdraws
      end
    end

    # ─────────────────────────────────────────────────────────────────────
    # WRITES THAT ALL FAIL must leave the ledger completely unchanged.
    # ─────────────────────────────────────────────────────────────────────
    describe "stress rollback: many ops, all raise inside perform" do
      it "commits zero entries when every concurrent op raises" do
        gid = 966_001
        seed_balance(gid:, amount: 100)
        entries_before = Entry.where(book_id:, gid:, currency: brl).count
        ops_before = Operation.count

        raising_op = Class.new(BaseOperation) do
          inputs :merchant_id, :currency
          def target_tuples
            tuples_for_pair(:merchant_balance, merchant_id, currency)
          end

          def perform(operation_id)
            ::Stern::EntryPair.add_merchant_balance(
              SecureRandom.random_number(1 << 30), merchant_id, 1, currency, operation_id:,
            )
            raise "deliberate mid-perform failure"
          end
        end
        stub_const("Stern::RollbackStress", raising_op)

        threads = 50.times.map do
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              RollbackStress.new(merchant_id: gid, currency: brl).call
            rescue RuntimeError
              # expected
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        end
        threads.each(&:join)

        # Every op raised mid-perform → full rollback. Neither the EntryPair
        # writes NOR the Operation audit rows should have committed.
        expect(Entry.where(book_id:, gid:, currency: brl).count).to eq(entries_before)
        expect(Operation.count).to eq(ops_before)
        assert_sacred!(gid:)
      end
    end

    # ─────────────────────────────────────────────────────────────────────
    # Repair must correctly interleave with heavy concurrent write load.
    # Even with corrupted starting state, after the storm the ledger is sane.
    # ─────────────────────────────────────────────────────────────────────
    describe "Repair under heavy concurrent write load" do
      it "keeps the cascade consistent even when Repair runs mid-storm" do
        gid = 967_001
        seed_balance(gid:, amount: 1_000)
        # Corrupt the seed entry to force Repair to actually do work.
        corrupt_balance = lambda do
          # rubocop:disable Rails/SkipsModelValidations
          Entry.where(book_id:, gid:, currency: brl).first
            .update_column(:ending_balance, 42_424_242)
          # rubocop:enable Rails/SkipsModelValidations
        end
        corrupt_balance.call

        deposit_op = Class.new(BaseOperation) do
          inputs :merchant_id, :uid, :currency
          def target_tuples
            tuples_for_pair(:merchant_balance, merchant_id, currency)
          end

          def perform(operation_id)
            ::Stern::EntryPair.add_merchant_balance(
              uid, merchant_id, 10, currency, operation_id:,
            )
          end
        end
        stub_const("Stern::HeavyDeposit", deposit_op)

        n = 100
        threads = n.times.map do |i|
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              HeavyDeposit.new(merchant_id: gid, uid: 50_000 + i, currency: brl).call
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        end

        # While those run, also fire a Repair rebuild. It should interleave
        # cleanly via the same advisory lock, not corrupt the ledger.
        repair_thread = Thread.new do
          ApplicationRecord.connection_pool.with_connection do
            Repair.rebuild_book_gid_balance(book_id, gid, brl)
          ensure
            ApplicationRecord.connection_pool.release_connection
          end
        end

        threads.each(&:join)
        repair_thread.join

        # Run one more Repair to normalize any remaining corruption from the
        # pre-seed tamper that ran before the first Repair could sequence it.
        Repair.rebuild_book_gid_balance(book_id, gid, brl)

        assert_sacred!(gid:)
        expect(Entry.where(book_id:, gid:, currency: brl).sum(:amount)).to eq(1_000 + n * 10)
      end
    end

    describe "log_operation failure releases the advisory lock" do
      it "two ops with same idem_key — second raises, third unrelated op proceeds promptly" do
        gid = 964_001
        seed_balance(gid:, amount: 500)
        idem_key = "lock-leak-probe-#{SecureRandom.hex(4)}"

        # First op reserves the idem_key.
        first_op_class = Class.new(BaseOperation) do
          inputs :merchant_id, :amount, :currency
          def target_tuples
            tuples_for_pair(:merchant_balance, merchant_id, currency)
          end

          def perform(operation_id)
            ::Stern::EntryPair.add_merchant_balance(
              SecureRandom.random_number(1 << 30), merchant_id, amount, currency, operation_id:,
            )
          end
        end
        stub_const("Stern::IdemProbe", first_op_class)

        IdemProbe.new(merchant_id: gid, amount: -10, currency: brl).call(idem_key:)

        # Second op with same idem_key but different params — must raise cleanly
        # (different-params guard in find_existing_operation).
        expect {
          IdemProbe.new(merchant_id: gid, amount: -999, currency: brl).call(idem_key:)
        }.to raise_error(/different parameters/)

        # Third op on same tuple must proceed within a tight timeout — lock was
        # NOT leaked by the raised second op.
        Timeout.timeout(2) do
          IdemProbe.new(merchant_id: gid, amount: -20, currency: brl).call
        end

        expect(Entry.where(book_id:, gid:, currency: brl).sum(:amount)).to eq(500 - 10 - 20)
        assert_sacred!(gid:)
      end
    end
  end
end
