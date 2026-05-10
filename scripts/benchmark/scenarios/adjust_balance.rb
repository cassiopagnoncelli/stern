# frozen_string_literal: true

require_relative "base"

module Benchmark
  module Scenarios
    # Benchmarks Stern::AdjustBalance, the admin "manual override" path. Each
    # call writes the `adjust_merchant_balance` pair (merchant_adjusted ↔
    # merchant_available). No runtime balance check — the op intentionally
    # skips guardrails — so this is the cleanest measurement of the
    # validate → log → lock → write loop without a state-dependent read.
    class AdjustBalance < Base
      def setup
        return unless opts[:reset]

        ::Stern::Repair.clear(confirm: true)
      end

      def run_once(iter_idx, thread_idx)
        merchant_id = merchant_ids[(thread_idx + iter_idx) % merchant_ids.size]
        ::Stern::AdjustBalance.new(
          merchant_id: merchant_id,
          amount: opts[:amount],
          currency: opts[:currency],
        ).call
      end

      private

      def merchant_ids
        @merchant_ids ||= (1..opts[:merchants]).map { |i| base_merchant_id + i }
      end

      def base_merchant_id
        900_000 + opts[:seed] % 10_000
      end
    end
  end
end
