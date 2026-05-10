# frozen_string_literal: true

require_relative "base"

module Benchmark
  module Scenarios
    # Benchmarks Stern::AddCredit, the "external grant" credit path. Each call
    # writes the `merchant_credit` pair (merchant_credit ↔ merchant_credit_0).
    # Contention is controlled by --merchants: same lock granularity as Deposit,
    # but the pair touches a different book set, so this isolates the cost of
    # the credit code path from the available-balance code path.
    class AddCredit < Base
      def setup
        return unless opts[:reset]

        ::Stern::Repair.clear(confirm: true)
      end

      def run_once(iter_idx, thread_idx)
        merchant_id = merchant_ids[(thread_idx + iter_idx) % merchant_ids.size]
        ::Stern::AddCredit.new(
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
