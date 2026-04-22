require "rails_helper"

module Stern
  RSpec.describe ProcessSopJob, type: :job do
    subject(:job) { described_class.new }

    describe "#perform" do
      let(:sop_id) { 42 }

      it "delegates to ScheduledOperationService.process_sop with the given id" do
        allow(ScheduledOperationService).to receive(:process_sop)
        job.perform(sop_id)
        expect(ScheduledOperationService).to have_received(:process_sop).with(sop_id)
      end

      # State-machine errors are expected outcomes under at-least-once
      # delivery. They mean "this SOP is not processable right now" — not
      # "something is broken." Swallowing them prevents a pointless Sidekiq
      # retry storm and keeps the job idempotent under redelivery.
      context "when the SOP has been deleted between enqueue and dispatch" do
        before do
          allow(ScheduledOperationService).to receive(:process_sop)
            .and_raise(ActiveRecord::RecordNotFound)
        end

        it "swallows ActiveRecord::RecordNotFound" do
          expect { job.perform(sop_id) }.not_to raise_error
        end
      end

      context "when the SOP is no longer in :picked (already processed, canceled, etc.)" do
        before do
          allow(ScheduledOperationService).to receive(:process_sop)
            .and_raise(CannotProcessNonPickedSopError)
        end

        it "swallows CannotProcessNonPickedSopError" do
          expect { job.perform(sop_id) }.not_to raise_error
        end
      end

      context "when the SOP's after_time is still in the future" do
        before do
          allow(ScheduledOperationService).to receive(:process_sop)
            .and_raise(CannotProcessAheadOfTimeError)
        end

        it "swallows CannotProcessAheadOfTimeError" do
          expect { job.perform(sop_id) }.not_to raise_error
        end
      end

      # Unexpected errors (DB connection lost, deserialization crash, etc.)
      # must propagate so the host's job backend (Sidekiq) can retry them.
      # Operation-level errors (ArgumentError, StandardError inside the op)
      # are already caught inside `process_operation` and never reach here.
      context "when process_sop raises an unexpected error" do
        before do
          allow(ScheduledOperationService).to receive(:process_sop)
            .and_raise(StandardError, "db connection lost")
        end

        it "propagates (so Sidekiq can retry the job)" do
          expect { job.perform(sop_id) }.to raise_error(StandardError, "db connection lost")
        end
      end
    end
  end
end
