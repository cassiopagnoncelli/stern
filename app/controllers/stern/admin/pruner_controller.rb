module Stern
  module Admin
    # Admin page for inspecting and triggering `Stern::OperationAttemptPruner`.
    # Phase 1: shows the configured retention windows, a per-status preview of
    # what a prune would delete right now, and a button to run a bounded prune
    # synchronously. No history persistence — operators audit runs via logs.
    class PrunerController < ::Stern::AuthenticatedController
      # Bounded synchronous run: ~50k rows at default batch size. Initial
      # backlog clearance must go through the rake task; the UI surfaces this
      # to the operator rather than papering over it with a long-running
      # request.
      MAX_BATCHES_PER_WEB_RUN = 50

      def index
        @retention = configured_retention
        @effective = effective_retention(@retention)
        @preview = ::Stern::OperationAttemptPruner.preview(**@effective)
      end

      def run
        overrides = parse_overrides(params)
        retention = effective_retention(configured_retention.merge(overrides))

        result = ::Stern::OperationAttemptPruner.call(
          **retention,
          max_batches: MAX_BATCHES_PER_WEB_RUN,
          triggered_by: "web:#{current_passport&.email}",
        )

        flash[:notice] =
          "Pruned success=#{result.success}, failed=#{result.failed}, pending=#{result.pending} " \
          "in #{(result.finished_at - result.started_at).round(2)}s."
      rescue ArgumentError => e
        flash[:alert] = "Could not run pruner: #{e.message}"
      ensure
        redirect_to admin_pruner_path
      end

      private

      # Reads the configured retention from ENV. Nil when unset — `effective_*`
      # decides what to substitute. Kept separate from `effective_retention`
      # so the view can show "default" labels distinctly from explicit values.
      def configured_retention
        {
          success_days: ENV["STERN_PRUNE_SUCCESS_DAYS"]&.to_i,
          failed_days:  ENV["STERN_PRUNE_FAILED_DAYS"]&.to_i,
          pending_days: ENV["STERN_PRUNE_PENDING_DAYS"]&.to_i
        }
      end

      DEFAULT_RETENTION = {
        success_days: 14,
        failed_days:  90,
        pending_days: 7
      }.freeze

      def effective_retention(values)
        DEFAULT_RETENTION.merge(values.compact)
      end

      # Sanitizes form input: blank fields fall through to the configured/default
      # value; non-blank fields must be non-negative integers. Out-of-range
      # values raise so the operator sees an error instead of a silently-wrong
      # prune.
      def parse_overrides(params)
        %i[success_days failed_days pending_days].each_with_object({}) do |key, h|
          raw = params[key]
          next if raw.blank?

          n = Integer(raw)
          raise ArgumentError, "#{key} must be >= 0" if n.negative?

          h[key] = n
        end
      end
    end
  end
end
