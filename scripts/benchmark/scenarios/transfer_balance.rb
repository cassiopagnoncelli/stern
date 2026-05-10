# frozen_string_literal: true

require_relative "base"

module Benchmark
  module Scenarios
    # Benchmarks Stern::TransferBalance, the cross-stakeholder available-balance
    # move. Each call locks two `(merchant_available, gid)` tuples (from + to)
    # and writes both pairs in one transaction, plus a runtime balance read on
    # the source. This is the most expensive of the "everyday" ops.
    #
    # Setup pre-deposits enough balance into each merchant to cover every
    # transfer the run will issue from it, so InsufficientFunds doesn't
    # contaminate the latency distribution.
    #
    # Requires `--merchants >= 2` so each iteration has a distinct from/to pair
    # (the op rejects transfers to self).
    class TransferBalance < Base
      def setup
        if opts[:merchants] < 2
          raise ArgumentError, "transfer_balance requires --merchants >= 2 (got #{opts[:merchants]})"
        end

        if opts[:reset]
          ::Stern::Repair.clear(confirm: true)
        end

        seed_amount = (opts[:iterations] + opts[:warmup]) * opts[:amount]
        merchant_ids.each do |mid|
          ::Stern::Deposit.new(
            merchant_id: mid,
            amount: seed_amount,
            currency: opts[:currency],
          ).call
        end
      end

      def run_once(iter_idx, thread_idx)
        size = merchant_ids.size
        idx = (thread_idx + iter_idx) % size
        from_id = merchant_ids[idx]
        to_id   = merchant_ids[(idx + 1) % size]

        ::Stern::TransferBalance.new(
          from_merchant_id: from_id,
          to_merchant_id: to_id,
          amount: opts[:amount],
          currency: opts[:currency],
          allow_overdraft: false,
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
