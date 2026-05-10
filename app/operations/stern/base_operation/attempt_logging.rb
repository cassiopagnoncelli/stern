module Stern
  class BaseOperation
    # Writes the `OperationAttempt` audit row for every `BaseOperation#call`.
    #
    # Contract — load-bearing for post-mortem visibility on failures:
    #   * `record_attempt!` runs **outside** the operation's transaction.
    #     The rescue paths in `#call` invoke it after the transaction has
    #     rolled back, so a failed attempt persists even though the
    #     `Operation` row that would have linked to it was destroyed by
    #     the rollback (`operation_id` stays nil on `:failed` rows).
    #   * Defensive: any exception raised from inside `OperationAttempt.create!`
    #     is logged and swallowed. The caller's actual error (whatever
    #     bubbled up from `perform`) takes precedence — masking it with
    #     a downstream audit-write failure would be worse than losing
    #     one audit entry.
    module AttemptLogging
      private

      # Writes an `OperationAttempt` row recording this call. Runs outside the
      # operation's transaction (the rescue path observes a rolled-back state),
      # so the attempt persists even when `perform` raises and the `Operation`
      # row is destroyed. Defensive: failures here are logged but never re-raised
      # — masking the caller's actual error would be worse than losing one audit
      # entry.
      def record_attempt!(status, attempted_at, params, idem_key, operation_id: nil, error: nil)
        OperationAttempt.create!(
          name: operation_name,
          params: params,
          idem_key: idem_key,
          operation_id: operation_id,
          status: status,
          attempted_at: attempted_at,
          error_class: error&.class&.name,
          error_message: error&.message,
          error_backtrace: error&.backtrace&.first(OperationAttempt::BACKTRACE_LINES)&.join("\n"),
        )
      rescue StandardError => attempt_error
        Rails.logger.error(
          "[Stern::BaseOperation] failed to record OperationAttempt " \
          "(#{operation_name}, status=#{status}): #{attempt_error.class}: #{attempt_error.message}"
        )
        nil
      end
    end
  end
end
