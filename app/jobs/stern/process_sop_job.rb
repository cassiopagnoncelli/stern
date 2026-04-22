module Stern
  # Per-SOP worker. Dispatched by `Stern::RunJob` (one job per pending SOP
  # id), runs under the host's ActiveJob backend — Sidekiq in practice for
  # apps using this engine, which gives at-least-once delivery for free.
  #
  # At-least-once means this `perform` can be redelivered. Idempotency is
  # guaranteed one level down via `process_sop` passing a stable idem_key
  # into `BaseOperation#call` (see `ScheduledOperationService#sop_idem_key`),
  # so a repeat run short-circuits to the already-committed Operation row
  # rather than double-writing.
  #
  # State-machine errors are expected outcomes under redelivery (the SOP
  # might have been processed by a prior attempt, canceled, or rescheduled
  # for the future). They're swallowed so they don't bleed into Sidekiq's
  # retry machinery and cause a retry storm. Genuinely unexpected errors
  # (DB connection loss, etc.) propagate so the backend can retry.
  class ProcessSopJob < ApplicationJob
    queue_as :default

    SWALLOWED_ERRORS = [
      ActiveRecord::RecordNotFound,
      CannotProcessNonPickedSopError,
      CannotProcessAheadOfTimeError,
    ].freeze

    def perform(scheduled_op_id)
      ScheduledOperationService.process_sop(scheduled_op_id)
    rescue *SWALLOWED_ERRORS => e
      Rails.logger.info(
        "Stern::ProcessSopJob skip sop=#{scheduled_op_id} " \
        "reason=#{e.class.name.demodulize}",
      )
    end
  end
end
