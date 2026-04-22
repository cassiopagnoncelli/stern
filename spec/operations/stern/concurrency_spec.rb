require "rails_helper"

# Guards the read-decide-write invariant under concurrent operations and proves
# the lock granularity allows parallelism on disjoint tuples. Uses a synthetic
# `WithdrawTest` operation so the test is not coupled to any real op's business
# rules. Transactional fixtures are disabled because worker threads need their
# own committed transactions; cleanup is manual via Stern::Repair.clear.
module Stern
  RSpec.describe "Operation concurrency", type: :model do
    self.use_transactional_tests = false

    let(:withdraw_class) do
      Class.new(BaseOperation) do
        inputs :merchant_id, :amount, :currency

        def target_tuples
          # Declared now so that once acquire_advisory_locks lands, this op
          # automatically gets the right lock. Under today's lock_tables
          # (table-level EXCLUSIVE) the declaration is dormant but harmless.
          [
            [ :merchant_balance, merchant_id, currency ],
            [ :merchant_balance_0, merchant_id, currency ]
          ]
        end

        def perform(operation_id)
          balance = ::Stern.balance(merchant_id, :merchant_balance, currency)
          raise ::Stern::InsufficientFunds, "balance #{balance} < amount #{amount}" if balance < amount

          ::Stern::EntryPair.add_merchant_balance(
            SecureRandom.random_number(1 << 30), merchant_id, -amount, currency, operation_id:,
          )
        end
      end
    end

    before { stub_const("Stern::WithdrawTest", withdraw_class) }

    let(:merchant_id) { 900_101 }
    let(:currency) { ::Stern.cur("BRL") }
    let(:book_id) { ::Stern.chart.book_code(:merchant_balance) }

    before { Repair.clear }
    after { Repair.clear }

    # Seeds `amount` into the merchant's balance via a deposit-shaped entry pair.
    def seed_balance(amount:)
      op = Operation.create!(name: "seed", params: {})
      EntryPair.add_merchant_balance(
        SecureRandom.random_number(1 << 30), merchant_id, amount, currency, operation_id: op.id,
      )
    end

    describe "sequential baseline" do
      it "allows a single withdraw that fits within the balance" do
        seed_balance(amount: 100)
        WithdrawTest.new(merchant_id:, amount: 80, currency:).call
        expect(::Stern.balance(merchant_id, :merchant_balance, currency)).to eq(20)
      end

      it "raises InsufficientFunds when a single withdraw exceeds the balance" do
        seed_balance(amount: 100)
        expect {
          WithdrawTest.new(merchant_id:, amount: 200, currency:).call
        }.to raise_error(InsufficientFunds)
      end
    end

    describe "read-decide-write safety on the same (book, gid, currency)" do
      # Three concurrent withdraws of 80 against seed 100. Only one can be funded;
      # the others must fail cleanly. Final balance must stay ≥ 0 and the ledger
      # must remain internally consistent.
      it "permits exactly one withdraw and rejects the rest" do
        seed_balance(amount: 100)

        errors = Queue.new
        successes = Queue.new

        threads = 3.times.map do
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              WithdrawTest.new(merchant_id:, amount: 80, currency:).call
              successes << :ok
            rescue InsufficientFunds
              errors << :insufficient
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        end
        threads.each(&:join)

        expect(successes.size).to eq(1)
        expect(errors.size).to eq(2)
        expect(::Stern.balance(merchant_id, :merchant_balance, currency)).to eq(20)
        expect(Doctor.ending_balance_consistent?(book_id:, gid: merchant_id, currency:)).to be(true)
        expect(Doctor.amount_consistent?).to be(true)
      end
    end

    # The specific race the user described: seed 100, two concurrent withdraws of 80.
    # Under a buggy lock, both "commit -80" and the ledger reads final balance = 20
    # (from the last-committed row) while physical sum = -60. Under correct locking,
    # exactly one withdraw succeeds and the balance stays at 20 with physical sum 20.
    describe "user's original Withdraw race (seed 100, two × -80)" do
      it "keeps balance ≥ 0 and makes read-balance match physical sum" do
        seed_balance(amount: 100)

        outcomes = Queue.new
        threads = 2.times.map do
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              WithdrawTest.new(merchant_id:, amount: 80, currency:).call
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
        expect(results.count(:insufficient)).to eq(1)

        # Balance from the stored ending_balance matches the physical sum of amounts.
        last_ending = Entry.where(book_id:, gid: merchant_id, currency:).order(:timestamp, :id).last.ending_balance
        physical_sum = Entry.where(book_id:, gid: merchant_id, currency:).sum(:amount)
        expect(last_ending).to eq(20)
        expect(physical_sum).to eq(20)
        expect(last_ending).to eq(physical_sum)  # split-brain detector

        # No duplicate ending_balance values — the cascade is a strict sequence.
        all_ending = Entry.where(book_id:, gid: merchant_id, currency:).pluck(:ending_balance)
        expect(all_ending).to eq(all_ending.uniq)
      end
    end

    # Sorted lock acquisition inside `acquire_advisory_locks` means two ops that
    # declare overlapping tuples in opposite orders still acquire them in the same
    # order, so they cannot deadlock. Demonstrated by running two ops, each
    # targeting two tuples declared in reverse order, concurrently — both complete.
    describe "deadlock prevention with reversed declaration order" do
      let(:op_ab_class) do
        Class.new(BaseOperation) do
          inputs :gid_a, :gid_b, :currency

          def target_tuples
            # Declares (merchant_balance, A) before (merchant_balance, B)
            [
              [ :merchant_balance,   gid_a, currency ],
              [ :merchant_balance,   gid_b, currency ]
            ]
          end

          def perform(operation_id)
            ::Stern::EntryPair.add_merchant_balance(
              SecureRandom.random_number(1 << 30), gid_a, 1, currency, operation_id:,
            )
            ::Stern::EntryPair.add_merchant_balance(
              SecureRandom.random_number(1 << 30), gid_b, 1, currency, operation_id:,
            )
          end
        end
      end

      let(:op_ba_class) do
        Class.new(BaseOperation) do
          inputs :gid_a, :gid_b, :currency

          def target_tuples
            # Declares (merchant_balance, B) before (merchant_balance, A) — reverse
            [
              [ :merchant_balance,   gid_b, currency ],
              [ :merchant_balance,   gid_a, currency ]
            ]
          end

          def perform(operation_id)
            ::Stern::EntryPair.add_merchant_balance(
              SecureRandom.random_number(1 << 30), gid_b, 1, currency, operation_id:,
            )
            ::Stern::EntryPair.add_merchant_balance(
              SecureRandom.random_number(1 << 30), gid_a, 1, currency, operation_id:,
            )
          end
        end
      end

      before do
        stub_const("Stern::OpAB", op_ab_class)
        stub_const("Stern::OpBA", op_ba_class)
      end

      it "does not deadlock when two ops touch the same tuples in opposite orders" do
        gid_a = 930_001
        gid_b = 930_002

        completed = Queue.new
        threads = [
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              OpAB.new(gid_a:, gid_b:, currency:).call
              completed << :ab
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end,
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              OpBA.new(gid_a:, gid_b:, currency:).call
              completed << :ba
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        ]

        deadline = Time.now + 3.0
        threads.each { |t| t.join(deadline - Time.now) }

        expect(threads.none?(&:alive?)).to be(true), "Threads did not complete — probable deadlock"

        results = []
        results << completed.pop until completed.empty?
        expect(results).to contain_exactly(:ab, :ba)
      end
    end

    describe "parallelism across different (book, gid, currency) tuples" do
      # Each thread withdraws from a DIFFERENT merchant. The goal is to show
      # that ops on disjoint tuples don't serialize. We include a deliberate
      # sleep inside perform to make the wall-time difference large enough to
      # assert without flakiness. Under a global table lock this sleep sums up
      # across threads; under per-tuple advisory locks the sleeps overlap.
      let(:slow_withdraw_class) do
        Class.new(BaseOperation) do
          inputs :merchant_id, :amount, :currency, :sleep_seconds

          def target_tuples
            [
              [ :merchant_balance, merchant_id, currency ],
              [ :merchant_balance_0, merchant_id, currency ]
            ]
          end

          def perform(operation_id)
            balance = ::Stern.balance(merchant_id, :merchant_balance, currency)
            raise ::Stern::InsufficientFunds if balance < amount

            sleep(sleep_seconds || 0)

            ::Stern::EntryPair.add_merchant_balance(
              SecureRandom.random_number(1 << 30), merchant_id, -amount, currency, operation_id:,
            )
          end
        end
      end

      before { stub_const("Stern::SlowWithdrawTest", slow_withdraw_class) }

      it "runs concurrently rather than serializing on unrelated merchants" do
        n = 4
        sleep_s = 0.15
        merchants = (1..n).map { |i| 900_200 + i }
        merchants.each do |mid|
          op = Operation.create!(name: "seed", params: {})
          EntryPair.add_merchant_balance(
            SecureRandom.random_number(1 << 30), mid, 100, currency, operation_id: op.id,
          )
        end

        t0 = Time.now
        threads = merchants.map do |mid|
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              SlowWithdrawTest.new(
                merchant_id: mid, amount: 80, currency:, sleep_seconds: sleep_s,
              ).call
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        end
        threads.each(&:join)
        wall = Time.now - t0

        # Strictly serialized would take ≈ n * sleep_s. Fully parallel would
        # take ≈ 1 * sleep_s. Assert wall time is well short of serialized.
        serialized_lower_bound = n * sleep_s
        expect(wall).to be < (0.5 * serialized_lower_bound)

        merchants.each do |mid|
          expect(::Stern.balance(mid, :merchant_balance, currency)).to eq(20)
        end
      end
    end
  end
end
