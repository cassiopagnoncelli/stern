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

    validates :name, presence: true, allow_blank: false, allow_nil: false
    validates :params, presence: true, allow_blank: true
    validates :after_time, presence: true
    validates :status, presence: true
    validates :status_time, presence: true

    after_initialize do
      self.params ||= {}
      self.status ||= :pending
      self.status_time ||= DateTime.current.utc
    end

    scope :next_batch, ->(size) { pending.where("after_time <= NOW()").limit(size) }

    def self.build(name: self.class.to_s, params:, after_time:, status: :pending, status_time: DateTime.current.utc)
      new(name:, params:, after_time:, status:, status_time:)
    end
  end
end
