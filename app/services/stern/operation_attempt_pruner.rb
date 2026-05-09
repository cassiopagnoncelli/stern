# frozen_string_literal: true

module Stern
  # Age-based hard delete for `Stern::OperationAttempt` rows. Each status has
  # its own retention window so debugging-relevant `failed` rows can outlive
  # routine `success` rows. `pending` rows older than the cutoff are reaped on
  # the same path — a stale `pending` is itself a bug signal (the attempt
  # should have been updated to success/failed) but should not pin the table.
  #
  # Deletes are batched on `id` to keep each statement small and to avoid
  # contending with concurrent `record_attempt!` inserts. A short sleep
  # between batches yields cycles to the writers under sustained pruning.
  #
  # Failure to write an attempt is swallowed by `BaseOperation#record_attempt!`,
  # so this service is the only enforcement of an upper bound on table size.
  # Treat it as load-bearing for any installation that retries through a
  # flapping external API.
  class OperationAttemptPruner
    DEFAULT_BATCH_SIZE = 1_000
    DEFAULT_SLEEP_BETWEEN = 0.1

    Result = Struct.new(:success, :failed, :pending, :started_at, :finished_at, keyword_init: true) do
      def total
        success + failed + pending
      end
    end

    def self.call(**kwargs)
      new(**kwargs).call
    end

    # Returns the per-status counts that a `call` *would* delete right now,
    # without performing any deletes. Used by the admin pruner page so an
    # operator can see the impact before committing to a run. Skipped statuses
    # (nil retention) report 0.
    def self.preview(success_days:, failed_days:, pending_days:, clock: -> { Time.current })
      now = clock.call
      { success: success_days, failed: failed_days, pending: pending_days }.to_h do |status, days|
        count =
          if days.nil?
            0
          else
            OperationAttempt
              .where(status: OperationAttempt.statuses.fetch(status.to_s))
              .where("attempted_at < ?", now - days.days)
              .count
          end
        [ status, count ]
      end
    end

    def initialize(
      success_days:,
      failed_days:,
      pending_days:,
      batch_size: DEFAULT_BATCH_SIZE,
      max_batches: nil,
      sleep_between: DEFAULT_SLEEP_BETWEEN,
      triggered_by: "unknown",
      logger: Rails.logger,
      clock: -> { Time.current }
    )
      @retention = {
        success: validate_days!(:success_days, success_days),
        failed:  validate_days!(:failed_days,  failed_days),
        pending: validate_days!(:pending_days, pending_days),
      }
      raise ArgumentError, "batch_size must be > 0" unless batch_size.is_a?(Integer) && batch_size.positive?
      raise ArgumentError, "max_batches must be > 0 or nil" if max_batches && !(max_batches.is_a?(Integer) && max_batches.positive?)
      raise ArgumentError, "sleep_between must be >= 0" unless sleep_between.is_a?(Numeric) && sleep_between >= 0

      @batch_size = batch_size
      @max_batches = max_batches
      @sleep_between = sleep_between
      @triggered_by = triggered_by
      @logger = logger
      @clock = clock
    end

    def call
      started_at = @clock.call
      counts = { success: 0, failed: 0, pending: 0 }

      @retention.each do |status, days|
        next if days.nil?

        cutoff = started_at - days.days
        counts[status] = prune_status(status, cutoff)
      end

      finished_at = @clock.call
      result = Result.new(
        success: counts[:success],
        failed: counts[:failed],
        pending: counts[:pending],
        started_at: started_at,
        finished_at: finished_at,
      )
      log_summary(result)
      result
    end

    private

    def validate_days!(key, value)
      return nil if value.nil?
      raise ArgumentError, "#{key} must be a non-negative Integer (got #{value.inspect})" unless value.is_a?(Integer) && value >= 0
      value
    end

    def prune_status(status, cutoff)
      deleted = 0
      batches = 0

      loop do
        ids = OperationAttempt
          .where(status: OperationAttempt.statuses.fetch(status.to_s))
          .where("attempted_at < ?", cutoff)
          .order(:id)
          .limit(@batch_size)
          .pluck(:id)
        break if ids.empty?

        deleted += OperationAttempt.where(id: ids).delete_all
        batches += 1
        break if @max_batches && batches >= @max_batches

        sleep(@sleep_between) if @sleep_between.positive?
      end

      deleted
    end

    def log_summary(result)
      @logger.info(
        "[Stern::OperationAttemptPruner] pruned " \
        "success=#{result.success} failed=#{result.failed} pending=#{result.pending} " \
        "elapsed=#{(result.finished_at - result.started_at).round(2)}s " \
        "triggered_by=#{@triggered_by}"
      )
    end
  end
end
