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

    CannotProcessNonPickedSopError = Class.new(StandardError)
    CannotProcessAheadOfTimeError = Class.new(StandardError)

    def list
      picked_list = ScheduledOperation.picked.ids
      picked_list = enqueue_list if picked_list.empty?
      picked_list
    end

    def enqueue_list(size = BATCH_SIZE)
      ScheduledOperation.pending.where("after_time <= NOW()").limit(size).then do |batch|
        batch.each_update!(status: :picked, status_time: DateTime.current.utc)
        batch.collect(&:id)
      end
    end

    def clear_picked
      ScheduledOperation
        .picked
        .where("status_time < ?", QUEUE_ITEM_TIMEOUT_IN_SECONDS.seconds.ago.utc)
        .each_update!(status: :pending, status_time: DateTime.current.utc)
    end

    def process_sop(scheduled_op_id)
      scheduled_op = ScheduledOperation.find(scheduled_op_id)

      raise ArgumentError unless scheduled_op
      raise CannotProcessNonPickedSopError unless scheduled_op.picked?
      raise CannotProcessAheadOfTimeError if scheduled_op.after_time > DateTime.current.utc

      scheduled_op.update!(status: :in_progress, status_time: DateTime.current.utc)

      op_klass = Object.const_get "Stern::#{scheduled_op.name}"
      operation = op_klass.new(**scheduled_op.params.symbolize_keys)
      process_operation(operation, scheduled_op)
    end

    def process_operation(operation, scheduled_op)
      raise ArgumentError, "sop not in progress" unless scheduled_op.in_progress?

      operation.call

      scheduled_op.update!(status: :finished, status_time: DateTime.current.utc)
    rescue ArgumentError => e
      scheduled_op.update!(
        status: :argument_error,
        status_time: DateTime.current.utc,
        error_message: e.message,
      )
    rescue StandardError => e
      scheduled_op.update!(
        status: :runtime_error,
        status_time: DateTime.current.utc,
        error_message: e.message,
      )
    end
  end
end
