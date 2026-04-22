module Stern
  # Periodic entry point for the SOP pipeline. Cron triggers this; the job
  # picks due SOPs via `ScheduledOperationService.list` and fans each one
  # out as its own `Stern::ProcessSopJob`, which the host's backend
  # (Sidekiq, in practice) runs with at-least-once delivery.
  #
  # Fan-out buys parallelism (multiple workers chew through the batch
  # concurrently) and isolation (one slow or failing op doesn't hold the
  # entire batch). Idempotency under redelivery is handled inside
  # `process_sop` via the propagated idem_key; see
  # `ScheduledOperationService#sop_idem_key`.
  class RunJob < ApplicationJob
    queue_as :default

    def perform(**_args)
      ScheduledOperationService.list.each do |sop_id|
        ProcessSopJob.perform_later(sop_id)
      end
    end
  end
end
