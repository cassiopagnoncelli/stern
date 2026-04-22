require "rails_helper"

module Stern
  RSpec.describe RunJob, type: :job do
    subject(:job) { described_class.new }

    describe "#perform" do
      let(:sop_ids) { [ 1, 2, 3 ] }

      before do
        allow(ScheduledOperationService).to receive(:list).and_return(sop_ids)
      end

      it "calls ScheduledOperationService.list to get pending SOP ids" do
        job.perform
        expect(ScheduledOperationService).to have_received(:list)
      end

      # The job now fans out. Each SOP id becomes its own ProcessSopJob
      # dispatched via the host's queue backend (Sidekiq in practice), so
      # individual SOPs can run in parallel and one slow op doesn't hold
      # the whole batch. This is why RunJob itself must NOT call process_sop
      # directly anymore — that responsibility moves to ProcessSopJob.
      it "enqueues a ProcessSopJob for each SOP id (fan-out)" do
        expect { job.perform }
          .to have_enqueued_job(ProcessSopJob).with(1)
          .and have_enqueued_job(ProcessSopJob).with(2)
          .and have_enqueued_job(ProcessSopJob).with(3)
      end

      it "does not invoke process_sop inline" do
        allow(ScheduledOperationService).to receive(:process_sop)
        job.perform
        expect(ScheduledOperationService).not_to have_received(:process_sop)
      end

      context "when no pending SOPs exist" do
        let(:sop_ids) { [] }

        it "enqueues no jobs" do
          expect { job.perform }.not_to have_enqueued_job(ProcessSopJob)
        end
      end
    end
  end
end
