module Stern
  class BaseOperation
    # Per-class retry configuration consumed by `Stern::ScheduledOperationService`.
    #
    # Contract: declare-time validation of `max_retries` / `backoff` / `base`,
    # one retry policy per subclass (no inheritance — re-declare in deeper
    # subclasses), `resolved_retry_policy` always returns a hash with all three
    # keys filled (declared values overlay `DEFAULT_RETRY_POLICY`, missing keys
    # fall back to the default by identity-preserving reference).
    module RetryPolicy
      # Default retry profile applied to subclasses that do not declare their
      # own `retry_policy`. Read by `Stern::ScheduledOperationService` at every
      # retry decision point. `:exponential` backoff yields `base * 2^retry_count`
      # (30s, 60s, 2m, 4m, 8m for retry_count 0..4 with base=30).
      DEFAULT_RETRY_POLICY = {
        max_retries: 5,
        backoff: :exponential,
        base: 30
      }.freeze

      SUPPORTED_BACKOFF_STRATEGIES = %i[exponential constant].freeze

      # Declares per-class retry behavior. Unspecified keys fall back to
      # `DEFAULT_RETRY_POLICY`. Backoff strategies:
      #   :exponential — base * 2^retry_count (default)
      #   :constant    — base seconds, every retry
      #
      # Constraints (validated at declaration time so misconfigurations
      # surface at boot, not when an op fails in production):
      #   max_retries — non-negative Integer (0 = fail-fast)
      #   base        — non-negative Numeric (Integer or Float seconds)
      #   backoff     — one of SUPPORTED_BACKOFF_STRATEGIES
      #
      # Example:
      #   class ChargePayment < BaseOperation
      #     retry_policy max_retries: 3, backoff: :constant, base: 60
      #   end
      def retry_policy(max_retries: nil, backoff: nil, base: nil)
        overrides = { max_retries: max_retries, backoff: backoff, base: base }.compact

        if overrides.key?(:max_retries)
          mr = overrides[:max_retries]
          unless mr.is_a?(Integer) && mr >= 0
            raise ArgumentError,
              "max_retries must be a non-negative Integer (got #{mr.inspect})"
          end
        end

        if overrides.key?(:base)
          b = overrides[:base]
          unless b.is_a?(Numeric) && b >= 0
            raise ArgumentError,
              "base must be a non-negative Numeric (got #{b.inspect})"
          end
        end

        if overrides[:backoff] && !SUPPORTED_BACKOFF_STRATEGIES.include?(overrides[:backoff])
          raise ArgumentError,
            "unknown backoff strategy: #{overrides[:backoff].inspect} " \
            "(supported: #{SUPPORTED_BACKOFF_STRATEGIES.inspect})"
        end

        @retry_policy = DEFAULT_RETRY_POLICY.merge(overrides)
      end

      # Returns the effective retry policy for this class. Falls back to
      # `DEFAULT_RETRY_POLICY` when `retry_policy` was never declared.
      def resolved_retry_policy
        @retry_policy || DEFAULT_RETRY_POLICY
      end
    end
  end
end
