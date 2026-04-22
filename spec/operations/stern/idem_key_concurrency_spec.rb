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
    def find_existing_operation(*args)
      result = super
      if (hook = Thread.current[:idem_key_race_barrier])
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
  end
end
