# frozen_string_literal: true

module Stern
  # Paginated list of OperationAttempt rows, optionally filtered by operation
  # name, status, idem_key, and an attempted_at window. Ordered by
  # attempted_at desc so the most recent attempts surface first — matching the
  # admin UI's "what just happened" reading order.
  #
  # Returns ActiveRecord scopes (not arrays of hashes) since OperationAttempt
  # is a regular AR model. Use #call for the page slice and #total_count for
  # the unpaginated total used by the pagination footer.
  class OperationAttemptsQuery < BaseQuery
    attr_accessor :name, :status, :idem_key, :start_date, :end_date, :page, :per_page

    # @param name [String, nil] exact match on the operation class name (e.g. "ChargePayment")
    # @param status [String, Symbol, nil] one of OperationAttempt.statuses
    # @param idem_key [String, nil] exact match on the idempotency key
    # @param start_date [Date, Time, DateTime, nil] inclusive lower bound on attempted_at
    # @param end_date [Date, Time, DateTime, nil] inclusive upper bound on attempted_at
    # @param page [Integer] 1-based page number
    # @param per_page [Integer] page size
    def initialize(name: nil, status: nil, idem_key: nil, start_date: nil, end_date: nil, page: 1, per_page: 25)
      raise ArgumentError, "page must be positive" if page <= 0
      raise ArgumentError, "per_page must be positive" if per_page <= 0

      self.name = name.presence
      self.status = resolve_status!(status)
      self.idem_key = idem_key.presence
      # No end-of-day expansion: operation attempts are precise events, not
      # day-bucketed line items, so the controller's wall-clock filter values
      # ("2026-05-01T12:00") should be honoured to the minute.
      self.start_date = start_date
      self.end_date = end_date
      self.page = page
      self.per_page = per_page
    end

    def call
      filtered_scope
        .order(attempted_at: :desc, id: :desc)
        .limit(per_page)
        .offset((page - 1) * per_page)
    end

    def total_count
      filtered_scope.count
    end

    private

    def filtered_scope
      scope = OperationAttempt.all
      scope = scope.where(name: name) if name
      scope = scope.where(status: status) if status
      scope = scope.where(idem_key: idem_key) if idem_key
      scope = scope.where("attempted_at >= ?", start_date) if start_date
      scope = scope.where("attempted_at <= ?", end_date) if end_date
      scope
    end

    # Accepts the string or symbol form of any OperationAttempt status; rejects
    # unknowns up front so the caller surfaces the bad input rather than
    # silently returning everything.
    def resolve_status!(value)
      return nil if value.blank?

      key = value.to_s
      raise ArgumentError, "unknown status #{value.inspect}" unless OperationAttempt.statuses.key?(key)

      key
    end
  end
end

__END__

# Examples:

OperationAttemptsQuery.new(
  status: :failed,
  start_date: 1.day.ago,
  end_date: Time.current,
  per_page: 100,
).call
