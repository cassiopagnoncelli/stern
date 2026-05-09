require "rails_helper"

module Stern
  RSpec.describe OperationAttemptPruner, type: :service do
    def make_attempt(status:, attempted_at:, name: "Test")
      OperationAttempt.create!(
        name: name,
        params: {},
        status: status,
        attempted_at: attempted_at,
      )
    end

    let(:now) { Time.zone.parse("2026-05-09 12:00:00") }
    let(:clock) { -> { now } }

    describe ".call" do
      it "deletes only rows older than the per-status cutoff" do
        keep_success = make_attempt(status: :success, attempted_at: now - 13.days)
        drop_success = make_attempt(status: :success, attempted_at: now - 15.days)
        keep_failed  = make_attempt(status: :failed,  attempted_at: now - 89.days)
        drop_failed  = make_attempt(status: :failed,  attempted_at: now - 91.days)
        keep_pending = make_attempt(status: :pending, attempted_at: now - 6.days)
        drop_pending = make_attempt(status: :pending, attempted_at: now - 8.days)

        result = described_class.call(
          success_days: 14, failed_days: 90, pending_days: 7,
          sleep_between: 0, clock: clock,
        )

        expect(OperationAttempt.where(id: [keep_success.id, keep_failed.id, keep_pending.id]).count).to eq(3)
        expect(OperationAttempt.where(id: [drop_success.id, drop_failed.id, drop_pending.id])).to be_empty
        expect(result.success).to eq(1)
        expect(result.failed).to eq(1)
        expect(result.pending).to eq(1)
        expect(result.total).to eq(3)
      end

      it "scopes deletes by status — success retention does not reach failed rows" do
        old_failed = make_attempt(status: :failed, attempted_at: now - 30.days)

        described_class.call(
          success_days: 1, failed_days: 90, pending_days: 1,
          sleep_between: 0, clock: clock,
        )

        expect(OperationAttempt.find_by(id: old_failed.id)).to be_present
      end

      it "skips a status entirely when its retention is nil" do
        ancient_success = make_attempt(status: :success, attempted_at: now - 365.days)

        result = described_class.call(
          success_days: nil, failed_days: 90, pending_days: 7,
          sleep_between: 0, clock: clock,
        )

        expect(OperationAttempt.find_by(id: ancient_success.id)).to be_present
        expect(result.success).to eq(0)
      end

      it "batches deletes when there are more rows than batch_size" do
        ids = Array.new(5) { make_attempt(status: :success, attempted_at: now - 30.days).id }

        result = described_class.call(
          success_days: 14, failed_days: 90, pending_days: 7,
          batch_size: 2, sleep_between: 0, clock: clock,
        )

        expect(OperationAttempt.where(id: ids)).to be_empty
        expect(result.success).to eq(5)
      end

      it "honours max_batches as an upper bound on a single run" do
        ids = Array.new(5) { make_attempt(status: :success, attempted_at: now - 30.days).id }

        result = described_class.call(
          success_days: 14, failed_days: 90, pending_days: 7,
          batch_size: 2, max_batches: 1, sleep_between: 0, clock: clock,
        )

        expect(OperationAttempt.where(id: ids).count).to eq(3)
        expect(result.success).to eq(2)
      end

      it "leaves rows exactly at the cutoff alone (strict <)" do
        edge = make_attempt(status: :success, attempted_at: now - 14.days)

        described_class.call(
          success_days: 14, failed_days: 90, pending_days: 7,
          sleep_between: 0, clock: clock,
        )

        expect(OperationAttempt.find_by(id: edge.id)).to be_present
      end
    end

    describe "argument validation" do
      it "rejects a negative retention value" do
        expect {
          described_class.new(success_days: -1, failed_days: 90, pending_days: 7)
        }.to raise_error(ArgumentError, /success_days/)
      end

      it "rejects a non-Integer retention value" do
        expect {
          described_class.new(success_days: 14.5, failed_days: 90, pending_days: 7)
        }.to raise_error(ArgumentError, /success_days/)
      end

      it "rejects a non-positive batch_size" do
        expect {
          described_class.new(success_days: 14, failed_days: 90, pending_days: 7, batch_size: 0)
        }.to raise_error(ArgumentError, /batch_size/)
      end

      it "rejects a non-positive max_batches" do
        expect {
          described_class.new(success_days: 14, failed_days: 90, pending_days: 7, max_batches: 0)
        }.to raise_error(ArgumentError, /max_batches/)
      end

      it "rejects a negative sleep_between" do
        expect {
          described_class.new(success_days: 14, failed_days: 90, pending_days: 7, sleep_between: -0.1)
        }.to raise_error(ArgumentError, /sleep_between/)
      end

      it "accepts zero retention (treats every row as past the cutoff)" do
        keep = make_attempt(status: :success, attempted_at: now + 1.minute)
        drop = make_attempt(status: :success, attempted_at: now - 1.minute)

        described_class.call(
          success_days: 0, failed_days: 90, pending_days: 7,
          sleep_between: 0, clock: clock,
        )

        expect(OperationAttempt.find_by(id: keep.id)).to be_present
        expect(OperationAttempt.find_by(id: drop.id)).to be_nil
      end
    end
  end
end
