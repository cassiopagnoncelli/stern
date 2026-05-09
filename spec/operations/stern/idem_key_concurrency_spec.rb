require "rails_helper"

# Proves `BaseOperation#call(idem_key: X)` is safe under two concurrent
# callers racing on the same key.
#
# The hazard: the existing check in `BaseOperation#call` does a SELECT
# `Operation.find_by(idem_key:)` first and only opens the transaction +
# inserts if no row is found. Two concurrent callers can both pass that
# check (each sees "no existing op"), then both try to INSERT. The partial
# unique index `stern_operations(idem_key) WHERE idem_key IS NOT NULL`
# catches one as `ActiveRecord::RecordNotUnique`. If `#call` doesn't handle
# that, the losing caller sees a DB violation bubble up as a generic
# StandardError — in the SOP pipeline that flips the scheduled operation to
# `:runtime_error` even though the work actually succeeded via the winning
# caller.
#
# Correct behavior: the losing caller detects the idem_key collision, reads
# the winning caller's Operation row, and returns that id. Both callers
# resolve to the same Operation, neither raises. Only one row persists.
#
# The spec pauses both workers between the SELECT and the INSERT via a
# thread-local hook on `find_existing_operation`, so the race window is
# provably open and not dependent on host-timing luck.
module Stern
  # Thread-local barrier hook fired after `find_existing_operation` returns,
  # i.e. after the SELECT by idem_key is done but before the INSERT path
  # begins. No-op unless the calling thread sets
  # `Thread.current[:idem_key_race_barrier]`.
  module IdemKeyRaceBarrier
    # Fires once per thread, then unhooks itself. `BaseOperation#call` may invoke
    # `find_existing_operation` a second time from the race-loser rescue path;
    # we only want to interleave on the pre-flight call, not the post-rollback
    # validation call.
    def find_existing_operation(*args)
      result = super
      if (hook = Thread.current[:idem_key_race_barrier])
        Thread.current[:idem_key_race_barrier] = nil
        hook.call
      end
      result
    end
  end

  RSpec.describe "BaseOperation idem_key race", type: :model do
    self.use_transactional_tests = false

    let(:trivial_class) do
      Class.new(BaseOperation) do
        inputs :tag

        def target_tuples
          []
        end

        def perform(operation_id); end
      end
    end

    before do
      stub_const("Stern::TrivialTestOp", trivial_class)
      BaseOperation.prepend(IdemKeyRaceBarrier) unless BaseOperation.include?(IdemKeyRaceBarrier)
      Repair.clear
    end

    after { Repair.clear }

    it "two concurrent callers with the same idem_key both resolve to the same Operation id" do
      key = "race-key-#{SecureRandom.hex(4)}"

      select_done = Queue.new
      insert_gate = Queue.new
      results = Queue.new

      threads = 2.times.map do
        Thread.new do
          Thread.current[:idem_key_race_barrier] = lambda do
            select_done << :read
            insert_gate.pop
          end
          ApplicationRecord.connection_pool.with_connection do
            id = TrivialTestOp.new(tag: 1).call(idem_key: key)
            results << [ :ok, id ]
          rescue StandardError => e
            results << [ :err, e.class.name, e.message ]
          ensure
            ApplicationRecord.connection_pool.release_connection
          end
        end
      end

      # Hold both workers past SELECT — both have seen "no existing op" —
      # then release both into the INSERT path. One's INSERT will race the
      # other's; the losing one must not surface RecordNotUnique.
      2.times { select_done.pop(timeout: 10) || raise("timed out waiting for a worker to reach barrier") }
      2.times { insert_gate << :go }

      deadline = Time.now + 10
      threads.each { |t| t.join([ deadline - Time.now, 0 ].max) }
      raise "worker thread did not finish" if threads.any?(&:alive?)

      outcomes = []
      outcomes << results.pop until results.empty?
      statuses = outcomes.map(&:first)

      expect(statuses).to eq([ :ok, :ok ]),
        "Expected both callers to succeed, got: #{outcomes.inspect}"

      ids = outcomes.map { |entry| entry[1] }
      expect(ids.uniq.size).to eq(1),
        "Expected both to resolve to the same Operation id, got: #{ids.inspect}"

      expect(Operation.where(idem_key: key).count).to eq(1)
    end

    # Regression: the race-loser path used to do a bare `Operation.find_by(idem_key:)`
    # and return the winner's id without comparing name/params. Two concurrent callers
    # using the same idem_key with *different* params would silently agree on the
    # winner's id — the loser's caller got back an Operation that didn't match the
    # call it just made. The pre-flight `find_existing_operation` raises on this; the
    # rescue must agree.
    it "raises on param mismatch when the loser is detected via the race-loser path" do
      key = "race-mismatch-#{SecureRandom.hex(4)}"

      select_done = Queue.new
      insert_gate = Queue.new
      results = Queue.new

      threads = [ 1, 999 ].map do |tag|
        Thread.new do
          Thread.current[:idem_key_race_barrier] = lambda do
            select_done << :read
            insert_gate.pop
          end
          ApplicationRecord.connection_pool.with_connection do
            id = TrivialTestOp.new(tag: tag).call(idem_key: key)
            results << [ :ok, tag, id ]
          rescue StandardError => e
            results << [ :err, tag, e.class.name, e.message ]
          ensure
            ApplicationRecord.connection_pool.release_connection
          end
        end
      end

      2.times { select_done.pop(timeout: 10) || raise("timed out waiting for a worker to reach barrier") }
      2.times { insert_gate << :go }

      deadline = Time.now + 10
      threads.each { |t| t.join([ deadline - Time.now, 0 ].max) }
      raise "worker thread did not finish" if threads.any?(&:alive?)

      outcomes = []
      outcomes << results.pop until results.empty?
      statuses = outcomes.map(&:first)

      expect(statuses.sort).to eq([ :err, :ok ]),
        "Expected exactly one winner and one mismatch raise, got: #{outcomes.inspect}"

      err = outcomes.find { |o| o.first == :err }
      expect(err[2]).to eq("Stern::IdempotencyConflict"),
        "Expected the loser to raise IdempotencyConflict, got: #{err.inspect}"

      expect(Operation.where(idem_key: key).count).to eq(1)
    end

    # Regression: the rescue used to swallow ANY RecordNotUnique whenever an
    # Operation row with the same idem_key existed, even when the violation came
    # from a different table/index entirely. That masked unrelated bugs in
    # `perform` as idempotent successes.
    it "does not swallow RecordNotUnique from indexes other than the idem_key one" do
      key = "race-foreign-#{SecureRandom.hex(4)}"
      Operation.create!(name: "TrivialTestOp", params: { "tag" => 1 }, idem_key: key)

      foreign_class = Class.new(BaseOperation) do
        inputs :tag

        def target_tuples; []; end

        def perform(_)
          raise ActiveRecord::RecordNotUnique.new("simulated entry-uniqueness collision")
        end
      end
      stub_const("Stern::ForeignDupOp", foreign_class)

      # Use a *different* idem_key for the racing caller so pre-flight finds
      # nothing; the RecordNotUnique we raise from `perform` has no PG cause
      # and therefore cannot be classified as an idem_key collision.
      expect {
        ForeignDupOp.new(tag: 1).call(idem_key: "foreign-#{SecureRandom.hex(4)}")
      }.to raise_error(ActiveRecord::RecordNotUnique, /simulated entry-uniqueness collision/)
    end
  end
end
