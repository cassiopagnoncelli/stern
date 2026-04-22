# frozen_string_literal: true

module Stern
  # Scheduled Operations Service.
  #
  # Scheduled operations are Operations to be executed in the future, immediately `after_time`.
  # This service is intended to be integrated with an at-least-once-delivery background job.
  #
  # Ideally items are reserved with `enqueue_list` providing a list of ServiceOperation ids which
  # should then be passed on to individual jobs each calling `preprocess_sop` on the id.
  #
  # Eventually reserved scheduled operations (marked `picked`) not executed may be reset via
  # `clear_picked`, thus having these items reappearing in `enqueue_list`. This routine can be
  # placed in a periodic job.
  #
  # You can safely copy the main job to your app while putting in a periodic routine.
  #
  module ScheduledOperationService
    module_function

    BATCH_SIZE = 100
    QUEUE_ITEM_TIMEOUT_IN_SECONDS = 300

    # How long a SOP may sit in `:in_progress` before `clear_in_progress`
    # considers the consumer dead and recycles it. Set longer than
    # `QUEUE_ITEM_TIMEOUT_IN_SECONDS` because in-progress means the op is
    # actually running — we want to give legitimate long-running ops time
    # to finish before assuming a crash.
    IN_PROGRESS_TIMEOUT_IN_SECONDS = 600

    # Max number of retries after the initial attempt before a transient
    # failure becomes the terminal `:runtime_error`. Total attempts =
    # MAX_RETRIES + 1.
    MAX_RETRIES = 5

    # Base backoff for the first retry, in seconds. Each subsequent retry
    # doubles it (exponential): 30s, 60s, 2m, 4m, 8m for retry_count 0..4.
    RETRY_BACKOFF_BASE_SECONDS = 30

    def list
      picked_list = ScheduledOperation.picked.ids
      picked_list = enqueue_list if picked_list.empty?
      picked_list
    end

    def enqueue_list(size = BATCH_SIZE)
      ActiveSupport::Notifications.instrument("stern.sop.enqueue_list") do |payload|
        ids = ScheduledOperation.transaction do
          picked_ids = ScheduledOperation
            .pending
            .where("after_time <= NOW()")
            .order(:id)
            .limit(size)
            .lock("FOR UPDATE SKIP LOCKED")
            .pluck(:id)

          if picked_ids.any?
            ScheduledOperation.where(id: picked_ids).update_all(
              status: ScheduledOperation.statuses[:picked],
              status_time: DateTime.current.utc,
            )
          end

          picked_ids
        end
        payload[:count] = ids.size
        ids
      end
    end

    def clear_picked
      ScheduledOperation
        .picked
        .where("status_time < ?", QUEUE_ITEM_TIMEOUT_IN_SECONDS.seconds.ago.utc)
        .each_update!(status: :pending, status_time: DateTime.current.utc)
    end

    # Recovers SOPs stuck in `:in_progress` past IN_PROGRESS_TIMEOUT_IN_SECONDS
    # — typically caused by a consumer crashing mid-op (OOM, SIGKILL, pod
    # eviction). On recovery, the crash counts as a failed attempt:
    # retry_count bumps, status returns to `:pending` with the same
    # exponential backoff as the StandardError rescue, and the op gets
    # another shot on the next picker tick. If retries are exhausted, the
    # SOP is marked `:runtime_error` terminally so it stops recycling.
    #
    # Intended to run periodically (host-app janitor job, alongside
    # `clear_picked`).
    def clear_in_progress
      threshold = IN_PROGRESS_TIMEOUT_IN_SECONDS.seconds.ago.utc
      ScheduledOperation.in_progress.where("status_time < ?", threshold).find_each do |sop|
        now = DateTime.current.utc
        if sop.retry_count < MAX_RETRIES
          sop.update!(
            status: :pending,
            status_time: now,
            after_time: now + retry_backoff(sop.retry_count),
            retry_count: sop.retry_count + 1,
            error_message: "recovered from stuck in_progress state",
          )
        else
          sop.update!(
            status: :runtime_error,
            status_time: now,
            error_message: "exceeded retries after stuck in_progress state",
          )
        end
      end
    end

    def process_sop(scheduled_op_id)
      scheduled_op = ScheduledOperation.find(scheduled_op_id)

      raise ArgumentError unless scheduled_op
      raise CannotProcessNonPickedSopError unless scheduled_op.picked?
      raise CannotProcessAheadOfTimeError if scheduled_op.after_time > DateTime.current.utc

      lag = (DateTime.current.utc.to_time - scheduled_op.after_time.to_time).to_f
      ActiveSupport::Notifications.instrument("stern.sop.pickup_lag", lag_seconds: lag)

      scheduled_op.update!(status: :in_progress, status_time: DateTime.current.utc)

      op_klass = Object.const_get "Stern::#{scheduled_op.name}"
      operation = op_klass.new(**scheduled_op.params.symbolize_keys)
      process_operation(operation, scheduled_op)
    end

    def process_operation(operation, scheduled_op)
      ActiveSupport::Notifications.instrument("stern.sop.process_operation") do |payload|
        payload[:op_name] = scheduled_op.name
        payload[:outcome] = :finished

        begin
          raise ArgumentError, "sop not in progress" unless scheduled_op.in_progress?

          operation.call(idem_key: sop_idem_key(scheduled_op))
          scheduled_op.update!(status: :finished, status_time: DateTime.current.utc)
        rescue ArgumentError => e
          payload[:outcome] = :argument_error
          scheduled_op.update!(
            status: :argument_error,
            status_time: DateTime.current.utc,
            error_message: e.message,
          )
        rescue StandardError => e
          if scheduled_op.retry_count < MAX_RETRIES
            payload[:outcome] = :retried
            now = DateTime.current.utc
            scheduled_op.update!(
              status: :pending,
              status_time: now,
              after_time: now + retry_backoff(scheduled_op.retry_count),
              retry_count: scheduled_op.retry_count + 1,
              error_message: e.message,
            )
          else
            payload[:outcome] = :runtime_error
            scheduled_op.update!(
              status: :runtime_error,
              status_time: DateTime.current.utc,
              error_message: e.message,
            )
          end
        end
      end
    end

    # Exponential backoff for the (retry_count)-th retry (0-indexed):
    # 30s, 60s, 2m, 4m, 8m for retry_count 0..4.
    def retry_backoff(retry_count)
      RETRY_BACKOFF_BASE_SECONDS * (2**retry_count)
    end

    # Stable per-SOP idempotency key, fed to `BaseOperation#call`. Any repeat
    # `process_sop` on the same SOP (at-least-once redelivery, manual re-pick,
    # clear_picked race) short-circuits to the existing Operation row instead
    # of re-running perform. Zero-padded so small ids still clear the
    # `Operation#idem_key` length floor of 8.
    def sop_idem_key(scheduled_op)
      "sop-#{scheduled_op.id.to_s.rjust(8, '0')}"
    end
  end
end
