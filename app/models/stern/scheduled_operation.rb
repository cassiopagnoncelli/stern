module Stern
  class ScheduledOperation < ApplicationRecord
    BATCH_SIZE = 100
    QUEUE_ITEM_TIMEOUT_IN_SECONDS = 300

    enum :status, {
      pending: 0,
      picked: 1,
      in_progress: 2,
      finished: 3,
      canceled: 4,
      argument_error: 11,
      runtime_error: 12,
    }

    validates :operation_def_id, presence: true
    validates :params, presence: true, allow_blank: true
    validates :after_time, presence: true
    validates :status, presence: true
    validates :status_time, presence: true

    belongs_to :operation_def, class_name: "Stern::OperationDef", optional: true,
                               primary_key: :operation_def_id, foreign_key: :id

    after_initialize do
      params || {}
      status || :pending
      status_time || DateTime.current.utc
    end

    scope :next_batch, lambda { |_size = BATCH_SIZE|
      pending.limit(BATCH_SIZE)
    }

    def self.execute_item(scheduled_op)
      scheduled_op.update!(status: :in_progress, status_time: DateTime.current.utc)

      klass = Object.const_get "Stern::#{scheduled_op.name}"
      object = klass.new(**scheduled_op.params.symbolize_keys)

      begin
        object.call

        scheduled_op.update!(status: :finished, status_time: DateTime.current.utc)
      rescue ArgumentError => e
        scheduled_op.update!(status: :argument_error, status_time: DateTime.current.utc,
                             error_message: e.message,)
      rescue StandardError => e
        scheduled_op.update!(status: :runtime_error, status_time: DateTime.current.utc,
                             error_message: e.message,)
      end
    end

    def self.requeue
      in_progress.where("status_time < ?", QUEUE_ITEM_TIMEOUT_IN_SECONDS.seconds.ago.utc)
                 .update_all(status: :pending)
    end

    def self.build(name:, params:, after_time:, status: :pending, status_time: DateTime.current.utc)
      operation_def_id = OperationDef.get_id_by_name!(name)
      new(operation_def_id:, params:, after_time:, status:, status_time:)
    end

    # Effectively replaces delegation to OperationDef saving a database query.
    def name
      OperationDef::Definitions.operation_classes_by_id[operation_def_id].name.gsub("Stern::", "")
    end
  end
end
