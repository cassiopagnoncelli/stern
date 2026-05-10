# frozen_string_literal: true

require_relative "base"

module Benchmark
  module Scenarios
    # Benchmarks Stern::Deposit, the simplest single-stakeholder credit path.
    # Each call writes the `confirm_deposit_merchant` pair (merchant_deposit ↔
    # merchant_available). Contention is controlled by --merchants: fewer ids →
    # more advisory-lock contention on the same `(merchant_available, gid)`
    # tuple; more ids → closer to fully parallel.
    class Deposit < Base
      def setup
        return unless opts[:reset]

        ::Stern::Repair.clear(confirm: true)
      end

      def run_once(iter_idx, thread_idx)
        merchant_id = merchant_ids[(thread_idx + iter_idx) % merchant_ids.size]
        ::Stern::Deposit.new(
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
