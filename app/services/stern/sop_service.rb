# frozen_string_literal: true

module Stern
  # Scheduled Operations Service.
  module SopService
    module_function

    BATCH_SIZE = 100
    QUEUE_ITEM_TIMEOUT_IN_SECONDS = 300

    def enqueue_list(size = BATCH_SIZE)
      ScheduledOperation.next_batch(size).then do |batch|
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
      scheduled_op = ScheduledOperation.find_by!(id: scheduled_op_id)
      scheduled_op.update!(status: :in_progress, status_time: DateTime.current.utc)

      op_klass = Object.const_get "Stern::#{scheduled_op.name}"
      operation = op_klass.new(**scheduled_op.params.symbolize_keys)
      process_operation(operation, scheduled_op)
    end

    def process_operation(operation, scheduled_op)
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
