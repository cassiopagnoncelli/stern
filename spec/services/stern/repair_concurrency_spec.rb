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

    # Cross-tuple rebuild race model — the piece deferred in the original
    # per-tuple locking plan (plans/brilliant-let-s-start-with-robust-hare.md,
    # "Repair service — its rebuild-vs-write race is a pre-existing issue").
    #
    # `rebuild_gid_balance` and `rebuild_balances` are piecewise: each
    # `(book, gid, currency)` is rebuilt inside its own transaction with its
    # own advisory lock. Between rebuilds, cross-book ops can commit.
    # Analysis says this is safe — each per-tuple rebuild produces a correct
    # cascade for its tuple, and writes between rebuilds go through
    # `create_entry_v04` which holds the same advisory lock and cascades
    # correctly. The final state is globally consistent even though the
    # rebuild is not atomic across tuples.
    #
    # These stress tests are the belt-and-suspenders proof. If there is a
    # subtle race the analysis missed, these catch it via S1/S2/S3.
    describe "cross-tuple rebuild safety under concurrent writes" do
      # AR's default pool size is 5 and default checkout_timeout is 5s. These
      # tests run 4 writer threads + 1 rebuilder, which fills the pool — a
      # thread that momentarily yields and comes back while another thread
      # reconnects can hit the 5s limit and get silently killed. Bump the
      # checkout timeout so serialization doesn't manifest as a phantom
      # pool-exhaustion error. Same pattern as the 1000-thread stress test
      # in `spec/models/stern/balance_invariant_spec.rb`.
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
      # Writes an amount to `(pp_charge_pix / pp_charge_pix_0, gid, cur)` —
      # a real two-book cascade via the shipping SQL function, so the race
      # model exercised is exactly production's.
      def write_charge_pix(gid:, amount:, currency:)
        op = Operation.create!(name: "rebuild_concurrency_writer", params: {})
        EntryPair.add_pp_charge_pix(
          SecureRandom.random_number(1 << 30), gid, amount, currency, operation_id: op.id,
        )
      end

      # S1+S2 check across every (book, gid, currency) in the DB.
      def assert_ledger_consistent!
        aggregate_failures "ledger invariants" do
          expect(Doctor.amount_consistent?).to be(true), "S2: sum(amount) != 0"

          # S1: ending_balance == running_sum(amount) per entry, across every tuple.
          Entry.distinct.pluck(:book_id, :gid, :currency).each do |bid, g, cur|
            consistent = Doctor.ending_balance_consistent?(book_id: bid, gid: g, currency: cur)
            expect(consistent).to be(true),
              "S1 violated for (book_id=#{bid}, gid=#{g}, currency=#{cur})"
          end
        end
      end

      it "rebuild_gid_balance interleaved with cross-book ops keeps all invariants" do
        # Single gid, many writes across (pp_charge_pix, pp_charge_pix_0).
        # Rebuilder hammers `rebuild_gid_balance(gid, cur)` while writers
        # hammer cross-book ops on the same gid. Any race in the piecewise
        # rebuild lets an ending_balance drift or a physical sum leak.
        #
        # Writer count: 3 (not higher). AR's connection pool defaults to 5,
        # and each worker thread holds a connection for the full body via
        # `with_connection`. 3 writers + 1 rebuilder + 1 headroom for the
        # main spec thread fits; 4 writers can starve the rebuilder at
        # pool checkout.
        target_gid = 940_101

        # Seed some history so the rebuilder has something to cascade.
        4.times { write_charge_pix(gid: target_gid, amount: 100, currency:) }

        stop_at = Time.now + 1.0  # enough for many interleavings to race
        writer_count = 3
        writes = Concurrent::AtomicFixnum.new(0)
        rebuilds = Concurrent::AtomicFixnum.new(0)

        writers = writer_count.times.map do
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              while Time.now < stop_at
                write_charge_pix(gid: target_gid, amount: 10, currency:)
                writes.increment
              end
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        end

        rebuild_errors = Queue.new
        rebuilder = Thread.new do
          ApplicationRecord.connection_pool.with_connection do
            while Time.now < stop_at
              Repair.rebuild_gid_balance(target_gid, currency)
              rebuilds.increment
            end
          rescue StandardError => e
            rebuild_errors << "#{e.class}: #{e.message}"
          ensure
            ApplicationRecord.connection_pool.release_connection
          end
        end

        (writers + [ rebuilder ]).each(&:join)

        # Surface any silently-swallowed exception so failures are diagnosable.
        errs = []
        errs << rebuild_errors.pop until rebuild_errors.empty?
        expect(errs).to be_empty, "rebuilder raised: #{errs.inspect}"

        # Meaningful load actually happened.
        expect(writes.value).to be > 0
        expect(rebuilds.value).to be > 0

        assert_ledger_consistent!
      end

      it "rebuild_balances interleaved with writes across many gids keeps all invariants" do
        # Scale up to the full-ledger rebuild. Many gids, each hit by
        # several writers, with `rebuild_balances` running repeatedly in
        # parallel. If cross-gid iteration order or the per-pair sub-txn
        # structure hid a race, this test catches it.
        gids = (950_001..950_008).to_a
        gids.each { |g| write_charge_pix(gid: g, amount: 100, currency:) }

        stop_at = Time.now + 1.0
        # See the note above on the sister test — pool-size constrained to
        # avoid starving the rebuilder at AR connection checkout.
        writer_count = 3
        writes = Concurrent::AtomicFixnum.new(0)
        rebuilds = Concurrent::AtomicFixnum.new(0)

        writers = writer_count.times.map do
          Thread.new do
            ApplicationRecord.connection_pool.with_connection do
              while Time.now < stop_at
                write_charge_pix(gid: gids.sample, amount: 10, currency:)
                writes.increment
              end
            ensure
              ApplicationRecord.connection_pool.release_connection
            end
          end
        end

        rebuild_errors = Queue.new
        rebuilder = Thread.new do
          ApplicationRecord.connection_pool.with_connection do
            while Time.now < stop_at
              Repair.rebuild_balances(confirm: true)
              rebuilds.increment
            end
          rescue StandardError => e
            rebuild_errors << "#{e.class}: #{e.message}"
          ensure
            ApplicationRecord.connection_pool.release_connection
          end
        end

        (writers + [ rebuilder ]).each(&:join)

        errs = []
        errs << rebuild_errors.pop until rebuild_errors.empty?
        expect(errs).to be_empty, "rebuilder raised: #{errs.inspect}"

        expect(writes.value).to be > 0
        expect(rebuilds.value).to be > 0

        assert_ledger_consistent!
      end
    end
  end
end
