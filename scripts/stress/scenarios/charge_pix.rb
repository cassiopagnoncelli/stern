# frozen_string_literal: true

require_relative "base"

module Stress
  module Scenarios
    # Benchmarks Stern::ChargePix. Each call writes a pp_charge_pix entry pair
    # for a rotating merchant_id. Contention is controlled by --merchants:
    # fewer merchants → more advisory-lock contention on the same tuple; more
    # merchants → closer to fully parallel. charge_id is globally unique per
    # (thread, iteration) so runs don't collide across restarts within a run.
    class ChargePix < Base
      def setup
        return unless opts[:reset]

        ::Stern::Repair.clear
      end

      def run_once(iter_idx, thread_idx)
        merchant_id = merchants[(thread_idx + iter_idx) % merchants.size]
        ::Stern::ChargePix.new(
          charge_id: next_charge_id,
          merchant_id: merchant_id,
          customer_id: customer_id_for(merchant_id),
          amount: opts[:amount],
          currency: opts[:currency],
        ).call
      end

      private

      def merchants
        @merchants ||= (1..opts[:merchants]).map { |i| base_merchant_id + i }
      end

      def base_merchant_id
        900_000 + opts[:seed] % 10_000
      end

      # Thread-safe monotonic charge_id. Seeded from run_id so parallel runs
      # against the same DB don't collide (charge_id × code × currency is unique).
      def next_charge_id
        @charge_counter_mutex ||= Mutex.new
        @charge_counter_mutex.synchronize do
          @charge_counter ||= opts[:run_id] * 10_000_000
          @charge_counter += 1
        end
      end

      def customer_id_for(merchant_id)
        merchant_id + 1_000_000
      end
    end
  end
end
