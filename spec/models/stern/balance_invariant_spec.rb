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
module Stern
  RSpec.describe "Balance invariants under concurrent load", type: :model do
    self.use_transactional_tests = false

    let(:brl) { ::Stern.cur("BRL") }
    let(:usd) { ::Stern.cur("USD") }
    let(:book_id) { ::Stern.chart.book_code(:merchant_balance) }
    let(:customer_book_id) { ::Stern.chart.book_code(:customer_balance) }

    before { Repair.clear }
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
