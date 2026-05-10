# frozen_string_literal: true

require_relative "base"

module Benchmark
  module Scenarios
    # Benchmarks Stern::ChargePayment. Each call writes one
    # `charge_<payment_method>` entry pair (e.g. `charged_pix` ↔ `payment` for
    # pix). The payment method is selected by --payment-method (default pix);
    # all values in Stern::ChargePayment::PAYMENT_METHODS are accepted.
    #
    # Contention is controlled by --merchants: fewer ids → more advisory-lock
    # contention on the same `(charge_<method>, payment_id)` tuple; more ids →
    # closer to fully parallel. charge_id is globally unique per (thread,
    # iteration) so runs don't collide across restarts within a run.
    class ChargePayment < Base
      def setup
        return unless opts[:reset]

        ::Stern::Repair.clear(confirm: true)
      end

      def run_once(iter_idx, thread_idx)
        payment_id = payment_ids[(thread_idx + iter_idx) % payment_ids.size]
        ::Stern::ChargePayment.new(
          charge_id: next_charge_id,
          payment_id: payment_id,
          payment_method: opts[:payment_method],
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
    end
  end
end
