module Stern
  class ScheduledOperation < ApplicationRecord
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

    belongs_to :operation_def,
               class_name: "Stern::OperationDef",
               optional: true,
               primary_key: :operation_def_id,
               foreign_key: :id,
               inverse_of: :scheduled_operations

    after_initialize do
      self.params ||= {}
      self.status ||= :pending
      self.status_time ||= DateTime.current.utc
    end

    scope :next_batch, ->(size) { pending.where("after_time <= NOW()").limit(size) }

    def self.build(name:, params:, after_time:, status: :pending, status_time: DateTime.current.utc)
      operation_def_id = OperationDef.get_id_by_name!(name)
      new(operation_def_id:, params:, after_time:, status:, status_time:)
    end

    # Effectively replaces delegation to OperationDef saving up a database query.
    def name
      OperationDef::Definitions
        .operation_classes_by_id[operation_def_id]
        .name
        .gsub("Stern::", "")
    end
  end
end
