# frozen_string_literal: true

require_relative "base"

module Benchmark
  module Scenarios
    # Benchmarks Stern::ChargeCreditCard. Each call writes a pp_charge_credit_card
    # entry pair (and optionally pp_charge_fee_merchant_credit_card when --fee > 0)
    # for a rotating merchant_id. Contention is controlled by --merchants: fewer
    # merchants → more advisory-lock contention on the same tuple; more merchants →
    # closer to fully parallel. charge_id is globally unique per (thread, iteration)
    # so runs don't collide across restarts within a run.
    class ChargeCreditCard < Base
      def setup
        return unless opts[:reset]

        ::Stern::Repair.clear
      end

      def run_once(iter_idx, thread_idx)
        merchant_id = merchants[(thread_idx + iter_idx) % merchants.size]
        ::Stern::ChargeCreditCard.new(
          charge_id: next_charge_id,
          merchant_id: merchant_id,
          customer_id: customer_id_for(merchant_id),
          amount: opts[:amount],
          fee: opts[:fee].positive? ? opts[:fee] : nil,
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
