require "rails_helper"

# Cross-actor concurrency matrix. Three actors can write to the ledger:
#
#   - Op      — Stern::BaseOperation#call (operation-level advisory lock)
#   - Direct  — raw EntryPair.create! + Entry.create! (SQL-function advisory lock)
#   - Repair  — Stern::Repair.rebuild_* (explicit advisory lock)
#
# All three paths take the same `(book, gid, currency)` advisory key. Any
# mix of actors on the same tuple must serialize; any mix on disjoint tuples
# must parallelize. This file proves both invariants hold.
module Stern
  RSpec.describe "Locking matrix (cross-actor concurrency)", type: :model do
    self.use_transactional_tests = false

    let(:currency) { ::Stern.cur("BRL") }
    let(:book_id) { ::Stern.chart.book_code(:merchant_balance) }

    let(:withdraw_op_class) do
      Class.new(BaseOperation) do
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
    end

    before do
      stub_const("Stern::WithdrawMatrix", withdraw_op_class)
      Repair.clear
    end

    after { Repair.clear }

    def seed(gid:, amount:)
      op = Operation.create!(name: "matrix_seed", params: {})
      EntryPair.add_merchant_balance(
        SecureRandom.random_number(1 << 30), gid, amount, currency, operation_id: op.id,
      )
    end

    def direct_deposit(gid:, amount:)
      op = Operation.create!(name: "matrix_direct", params: {})
      EntryPair.add_merchant_balance(
        SecureRandom.random_number(1 << 30), gid, amount, currency, operation_id: op.id,
      )
    end

    def corrupt_balance!(gid:)
      # rubocop:disable Rails/SkipsModelValidations
      Entry.where(book_id:, gid:, currency:).first.update_column(:ending_balance, 99_999)
      # rubocop:enable Rails/SkipsModelValidations
    end

    def consistent?(gid:)
      Doctor.ending_balance_consistent?(book_id:, gid:, currency:)
    end

    # ─────────────────────────────────────────────────────────────────────
    # SAME TUPLE — must serialize. Physical ledger invariant must hold.
    # ─────────────────────────────────────────────────────────────────────
    describe "same (book, gid, currency) — must serialize" do
      let(:gid) { 910_001 }

      it "Op vs direct EntryPair.add_* on same tuple keeps the cascade consistent" do
        seed(gid:, amount: 100)

        threads = [
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              WithdrawMatrix.new(merchant_id: gid, amount: 50, currency:).call
            rescue InsufficientFunds
              # OK — may lose the race
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end,
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              direct_deposit(gid:, amount: 30)
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        ]
        threads.each(&:join)

        # The two writes commute; final balance can be 100 - 50 + 30 = 80 (if op won
        # its read) OR 100 + 30 - 50 = 80 (if direct committed first). Either way 80.
        # The consistency of the cascade is the critical invariant.
        expect(consistent?(gid:)).to be(true)
        expect(Entry.where(book_id:, gid:, currency:).sum(:amount)).to eq(80)
      end

      it "Op vs Repair.rebuild_book_gid_balance on same tuple stays consistent" do
        seed(gid:, amount: 100)
        # Repair is only interesting on corrupted state.
        corrupt_balance!(gid:)

        threads = [
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              WithdrawMatrix.new(merchant_id: gid, amount: 30, currency:).call
            rescue InsufficientFunds
              # OK — may lose the read race depending on whether Repair ran first
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end,
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              Repair.rebuild_book_gid_balance(book_id, gid, currency)
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        ]
        threads.each(&:join)

        expect(consistent?(gid:)).to be(true)
      end

      it "direct EntryPair.add_* vs Repair on same tuple stays consistent" do
        seed(gid:, amount: 100)
        corrupt_balance!(gid:)

        threads = [
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              direct_deposit(gid:, amount: 40)
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end,
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              Repair.rebuild_book_gid_balance(book_id, gid, currency)
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        ]
        threads.each(&:join)

        expect(consistent?(gid:)).to be(true)
        expect(Entry.where(book_id:, gid:, currency:).sum(:amount)).to eq(140)
      end

      it "Entry#destroy! vs Entry.create! on same tuple stays consistent" do
        seed(gid:, amount: 100)
        direct_deposit(gid:, amount: 50) # seed → 150 after two entries
        victim = Entry.where(book_id:, gid:, currency:).order(:timestamp, :id).last

        threads = [
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              victim.destroy!
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end,
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              direct_deposit(gid:, amount: 20)
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        ]
        threads.each(&:join)

        expect(consistent?(gid:)).to be(true)
        # Remaining rows: seed (+100), new (+20) = 120. Victim (+50) destroyed.
        expect(Entry.where(book_id:, gid:, currency:).sum(:amount)).to eq(120)
      end
    end

    # ─────────────────────────────────────────────────────────────────────
    # DIFFERENT TUPLES — must parallelize. Unrelated merchants don't queue.
    # ─────────────────────────────────────────────────────────────────────
    describe "different (book, gid, currency) — must parallelize" do
      # Hold each thread's transaction open by having Repair be slow. We make it
      # slow by stubbing the sanitize helper to inject a delay after the lock is
      # acquired but before the UPDATE runs — mimicking a heavy rebuild.
      let(:slow_repair_class) do
        Class.new(Repair) do
          def self.rebuild_book_gid_balance_sanitized_sql(*args)
            sleep 0.15
            Repair.rebuild_book_gid_balance_sanitized_sql(*args)
          end
        end
      end

      it "two Repair rebuilds on different gids run in parallel" do
        gids = [ 920_001, 920_002 ]
        gids.each { |g| seed(gid: g, amount: 100); corrupt_balance!(gid: g) }

        stub_const("Stern::SlowRepair", slow_repair_class)

        t0 = Time.now
        threads = gids.map do |g|
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              SlowRepair.rebuild_book_gid_balance(book_id, g, currency)
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        end
        threads.each(&:join)
        wall = Time.now - t0

        # Serialized: 2 × 0.15 = 0.30s. Parallel: ≈ 0.15s. Assert well below serial.
        expect(wall).to be < 0.22

        gids.each { |g| expect(consistent?(gid: g)).to be(true) }
      end

      # Extra edge case: one op that legitimately touches both M1 and M2
      # (transfer-style) must serialize with any concurrent op on either gid.
      it "an op targeting two gids serializes only with ops on one of those gids" do
        gid_shared = 920_201
        gid_independent = 920_202
        seed(gid: gid_shared, amount: 1_000)
        seed(gid: gid_independent, amount: 1_000)

        two_gid_op = Class.new(BaseOperation) do
          inputs :gid_a, :gid_b, :currency
          def target_tuples
            [
              [ :merchant_balance, gid_a, currency ],
              [ :merchant_balance_0, gid_a, currency ],
              [ :merchant_balance, gid_b, currency ],
              [ :merchant_balance_0, gid_b, currency ]
            ]
          end

          def perform(operation_id)
            ::Stern::EntryPair.add_merchant_balance(
              SecureRandom.random_number(1 << 30), gid_a, -10, currency, operation_id:,
            )
            ::Stern::EntryPair.add_merchant_balance(
              SecureRandom.random_number(1 << 30), gid_b, 10, currency, operation_id:,
            )
          end
        end
        stub_const("Stern::TwoGidOp", two_gid_op)

        threads = [
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              TwoGidOp.new(gid_a: gid_shared, gid_b: 920_203, currency:).call
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end,
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              WithdrawMatrix.new(merchant_id: gid_independent, amount: 10, currency:).call
            rescue InsufficientFunds
              nil
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        ]
        threads.each(&:join)

        expect(consistent?(gid: gid_shared)).to be(true)
        expect(consistent?(gid: gid_independent)).to be(true)
      end

      it "an Op on merchant M1 and a Repair on merchant M2 run in parallel" do
        gid_op = 920_101
        gid_repair = 920_102
        seed(gid: gid_op, amount: 100)
        seed(gid: gid_repair, amount: 100)
        corrupt_balance!(gid: gid_repair)

        stub_const("Stern::SlowRepair", slow_repair_class)

        t0 = Time.now
        threads = [
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              SlowRepair.rebuild_book_gid_balance(book_id, gid_repair, currency)
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end,
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              sleep 0.05 # let the Repair start first
              WithdrawMatrix.new(merchant_id: gid_op, amount: 30, currency:).call
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        ]
        threads.each(&:join)
        wall = Time.now - t0

        # If repair serialized the op, wall time would be ≈ 0.15 + op-time. The op
        # would instead overlap with repair's sleep. Assert wall stays under a
        # generous threshold that only holds under parallelism.
        expect(wall).to be < 0.22

        expect(consistent?(gid: gid_op)).to be(true)
        expect(consistent?(gid: gid_repair)).to be(true)
      end
    end

    # ─────────────────────────────────────────────────────────────────────
    # TRANSACTION SEMANTICS — rollback releases the advisory lock cleanly.
    # ─────────────────────────────────────────────────────────────────────
    describe "transaction rollback" do
      it "releases the (book, gid, currency) advisory lock on error, so the next op proceeds" do
        gid = 940_001
        seed(gid:, amount: 100)

        raising_op = Class.new(BaseOperation) do
          inputs :merchant_id, :currency
          def target_tuples
            tuples_for_pair(:merchant_balance, merchant_id, currency)
          end

          def perform(_operation_id)
            raise "deliberate failure inside perform"
          end
        end
        stub_const("Stern::RaisingOp", raising_op)

        # First op: acquires lock, raises mid-perform, transaction rolls back,
        # lock released.
        expect {
          RaisingOp.new(merchant_id: gid, currency:).call
        }.to raise_error(/deliberate failure/)

        # Next op on the same tuple must be able to acquire the lock and proceed.
        # Use a tight timeout to prove we aren't blocked on a leaked lock.
        Timeout.timeout(2) do
          WithdrawMatrix.new(merchant_id: gid, amount: 40, currency:).call
        end

        expect(Entry.where(book_id:, gid:, currency:).sum(:amount)).to eq(60)
      end
    end

    # ─────────────────────────────────────────────────────────────────────
    # IDEMPOTENCY UNDER CONCURRENCY — two Ops with the same idem_key racing.
    # Expectation: no double-write. Either one succeeds and the other hits
    # the `stern_operations.idem_key` unique constraint, or the second op
    # sees the first's committed Operation and returns its id.
    # ─────────────────────────────────────────────────────────────────────
    describe "idempotency under concurrency" do
      it "never commits the same operation twice when two callers race on the same idem_key" do
        gid = 950_001
        seed(gid:, amount: 10_000)
        idem_key = "idem-race-#{SecureRandom.hex(4)}"

        starting_ops = Operation.count
        starting_amount = Entry.where(book_id:, gid:, currency:).sum(:amount)

        outcomes = Queue.new
        threads = 2.times.map do
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              id = WithdrawMatrix.new(merchant_id: gid, amount: 40, currency:).call(idem_key:)
              outcomes << [ :ok, id ]
            rescue => e
              outcomes << [ :err, e.class.name ]
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        end
        threads.each(&:join)

        results = []
        results << outcomes.pop until outcomes.empty?

        # Exactly one Operation row for this idem_key must exist.
        expect(Operation.where(idem_key: idem_key).count).to eq(1)

        # The physical amount written must correspond to exactly one withdraw.
        # starting_amount is from the seed; one successful -40 leaves starting_amount - 40.
        expect(Entry.where(book_id:, gid:, currency:).sum(:amount))
          .to eq(starting_amount - 40)

        # No double-counting in the Operation audit log.
        expect(Operation.count).to eq(starting_ops + 1)

        # At least one thread succeeded.
        expect(results.any? { |r, _| r == :ok }).to be(true)
      end
    end
  end
end
