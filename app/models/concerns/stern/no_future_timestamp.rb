# frozen_string_literal: true

# Rejects records whose `timestamp` column is set to a future time. Uses an ActiveRecord
# validation so `save` returns false and `save!` raises `RecordInvalid` — the idiomatic Rails
# contract. Does nothing when `timestamp` is nil (treated as "not specified").
module Stern
  module NoFutureTimestamp
    extend ActiveSupport::Concern

    included do
      validate :no_future_timestamp
    end

    private

    def no_future_timestamp
      return unless timestamp.present? && timestamp > DateTime.current

      errors.add(:timestamp, "cannot be in the future")
    end
  end
end
