# frozen_string_literal: true

require_relative "base"

module Benchmark
  module Scenarios
    # Benchmarks Stern::ChargePix. Each call writes pay_pix + pp_charge_pix +
    # pp_charge + a customer pair for a rotating payment_id. Contention is
    # controlled by --merchants: fewer ids → more advisory-lock contention on
    # the same tuple; more ids → closer to fully parallel. charge_id is
    # globally unique per (thread, iteration) so runs don't collide across
    # restarts within a run.
    class ChargePix < Base
      def setup
        return unless opts[:reset]

        ::Stern::Repair.clear
      end

      def run_once(iter_idx, thread_idx)
        payment_id = payment_ids[(thread_idx + iter_idx) % payment_ids.size]
        ::Stern::ChargePix.new(
          charge_id: next_charge_id,
          payment_id: payment_id,
          customer_id: customer_id_for(payment_id),
          amount: opts[:amount],
          currency: opts[:currency],
        ).call
      end

      private

      def payment_ids
        @payment_ids ||= (1..opts[:merchants]).map { |i| base_payment_id + i }
      end

      def base_payment_id
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

      def customer_id_for(payment_id)
        payment_id + 1_000_000
      end
    end
  end
end
