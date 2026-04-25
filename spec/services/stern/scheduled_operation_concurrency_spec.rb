require "rails_helper"

# Proves that `ScheduledOperationService.enqueue_list` picks each pending SOP
# into exactly one worker's batch, even under two concurrent callers.
#
# The picker reserves rows with `SELECT ... FOR UPDATE SKIP LOCKED` inside a
# transaction, so worker B's SELECT skips rows worker A already locked. To
# make the race window deterministic (rather than relying on Ruby-level
# timing), this spec installs a thread-local barrier that pauses each worker
# inside its transaction right after `pluck` — the SELECT has taken its
# row-locks and returned its id list, but the transaction is still open and
# the locks still held. Both workers reach that paused state (regardless of
# how many rows either one's SELECT returned) before either is released, so
# they are provably inside their own row-lock-holding transactions at the
# same moment.
#
# Under the old implementation (plain `SELECT ... LIMIT N` + per-row UPDATE
# outside a transaction, no row-locks), both workers read the same rows and
# both return them — the same id appears in both batches, causing downstream
# `process_sop` to run the operation twice (two `Operation` rows, two
# `EntryPair` sets — a real double-spend).
#
# Transactional fixtures are disabled so each worker thread sees the others'
# committed writes; cleanup is manual via `ScheduledOperation.delete_all`.
module Stern
  # Thread-local barrier hook fired AFTER `pluck` on any `ScheduledOperation`
  # relation — i.e., after the SELECT ... FOR UPDATE SKIP LOCKED inside
  # `enqueue_list` has returned its result set but while the transaction is
  # still open and row-locks still held. Both workers always reach `pluck`
  # (regardless of how many rows they got), so the barrier is symmetric
  # even when one worker wins the race entirely and the other gets an empty
  # result set. A no-op unless the calling thread sets
  # `Thread.current[:sop_picker_barrier]` to a callable. Defined at module
  # level so `prepend` sees a stable constant across RSpec re-loads.
  module SopPickerBarrier
    def pluck(*args)
      result = super
      if (hook = Thread.current[:sop_picker_barrier])
        hook.call
      end
      result
    end
  end

  RSpec.describe "ScheduledOperationService concurrent picking", type: :service do
    self.use_transactional_tests = false

    let(:name) { "ChargePix" }
    let(:params) do
      { charge_id: 1, payment_id: 1101, customer_id: 2, amount: 9900, currency: "usd" }
    end
    let(:after_time) { 1.minute.ago.utc }

    before do
      ScheduledOperation.delete_all
      rel_class = ScheduledOperation.const_get(:ActiveRecord_Relation)
      rel_class.prepend(SopPickerBarrier) unless rel_class.include?(SopPickerBarrier)
    end

    after { ScheduledOperation.delete_all }

    def seed_pending(count)
      count.times.map do |i|
        ScheduledOperation.create!(
          name: name,
          params: params.merge(charge_id: i + 1),
          after_time: after_time,
          status: :pending,
        ).id
      end
    end

    it "picks each pending SOP into exactly one worker's batch" do
      seeded_ids = seed_pending(20)

      select_done = Queue.new
      update_gate = Queue.new

      threads = 2.times.map do
        Thread.new do
          Thread.current[:sop_picker_barrier] = lambda do
            select_done << :read
            update_gate.pop
          end
          ApplicationRecord.connection_pool.with_connection do
            ScheduledOperationService.enqueue_list(50)
          ensure
            ApplicationRecord.connection_pool.release_connection
          end
        end
      end

      # Both workers must reach the paused state (post-SELECT-FOR-UPDATE,
      # still holding row locks) before either commits. Timeouts guard
      # against a future regression leaving a worker's transaction open and
      # hanging the whole suite.
      2.times { select_done.pop(timeout: 10) || raise("timed out waiting for a worker to reach barrier") }
      2.times { update_gate << :go }

      deadline = Time.now + 10
      threads.each { |t| t.join([ deadline - Time.now, 0 ].max) }
      raise "worker thread did not finish" if threads.any?(&:alive?)
      batches = threads.map(&:value)
      combined = batches.flatten

      duplicates = combined.tally.select { |_, c| c > 1 }
      expect(duplicates).to(
        be_empty,
        "Expected no SOP id to appear in more than one worker's batch, " \
        "but these were double-picked: #{duplicates.inspect}. " \
        "Batches sizes: #{batches.map(&:size).inspect}",
      )

      # Every returned id must be one we seeded.
      expect(combined - seeded_ids).to be_empty

      # Every picked SOP must actually be in status :picked now.
      expect(ScheduledOperation.where(id: combined).pluck(:status).uniq)
        .to eq([ "picked" ])

      # The disjoint union across workers covers the full seeded set —
      # no seeded row was leaked out of the pick.
      expect(combined.sort).to eq(seeded_ids.sort)
    end
  end
end
