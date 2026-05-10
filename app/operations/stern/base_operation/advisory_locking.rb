module Stern
  class BaseOperation
    # Per-tuple Postgres advisory locking taken before `perform` runs.
    #
    # Contract — and the deadlock-prevention invariant the rest of the engine
    # depends on:
    #
    #   * `target_tuples` returns the `(book, gid, currency)` triples this
    #     operation reads from or writes to. Default is `[]` (opt out of
    #     locking — the op has no data dependency).
    #   * `acquire_advisory_locks` resolves any Symbol/String book references
    #     to integer codes via the chart, then **sorts the result by
    #     `[book_id, gid, currency]` and dedupes** before taking each lock.
    #     This canonical ordering is the load-bearing piece: any two
    #     operations that share even one tuple acquire that tuple — and any
    #     other shared tuple — in the same order regardless of how their
    #     `target_tuples` arrays are written. Without it, two ops that
    #     declare overlapping tuples in opposite orders can deadlock.
    #   * `pg_advisory_xact_lock` (via `ApplicationRecord.advisory_lock`) is
    #     reentrant within a transaction and releases at commit/rollback —
    #     so the `BaseOperation#call` transaction is the lock's lifetime.
    #
    # Disjoint tuples never collide: ops on different `(book, gid, currency)`
    # triples acquire independent locks and run in parallel. See
    # `spec/operations/stern/concurrency_spec.rb` for the deadlock-prevention
    # and parallelism proofs.
    module AdvisoryLocking
      # Declares the `(book, gid, currency)` tuples this operation reads from or writes
      # to. `BaseOperation#call` takes a per-tuple Postgres advisory lock on each before
      # `perform` runs, so concurrent ops on the same tuples serialize while ops on
      # disjoint tuples run in parallel.
      #
      # Subclasses override with something like:
      #
      #   def target_tuples
      #     tuples_for_pair(:pp_charge_pix, merchant_id, merchant_id, currency)
      #   end
      #
      # Book references can be Symbols/Strings (resolved via the chart) or integer codes.
      # Return [] to opt out of locking (the operation has no data dependency).
      def target_tuples
        []
      end

      private

      # Helper for the common double-entry pattern: returns the two `(book, gid, currency)`
      # tuples to lock for an `EntryPair.add_<pair_name>(...)` write. Each gid is the
      # natural sharding entity for its side's book — independent of the other side
      # and independent of the single `gid` the caller passes to `EntryPair.add_<pair_name>`.
      #
      # Examples:
      #
      #   * ChargePayment (`charge_<method>`: book_sub=payment_<method>, book_add=payment)
      #     — sub side is sharded by `charge_id` (one charge per row in `payment_<method>`),
      #     add side by `payment_id` — pass `(charge_id, payment_id)`.
      #
      #   * ChargePaymentFee (`charge_<method>_fee_merchant`: book_sub=merchant_available,
      #     book_add=payment_fee_<method>) — sub side by the stakeholder, add side by the
      #     payment — pass `(merchant_id, payment_id)`.
      #
      #   * TransferBalance (`merchant_available`) — both sides sharded by the same
      #     `merchant_id` — pass it twice.
      def tuples_for_pair(pair_name, book_sub_gid, book_add_gid, currency)
        pair = ::Stern.chart.entry_pair(pair_name)
        raise ArgumentError, "unknown entry pair #{pair_name.inspect}" unless pair

        [ [ pair.book_sub, book_sub_gid, currency ], [ pair.book_add, book_add_gid, currency ] ]
      end

      # Takes a transaction-scoped Postgres advisory lock on each `(book_id, gid, currency)`
      # tuple. Sorts by `[book_id, gid, currency]` to eliminate deadlock risk: any two
      # concurrent operations requesting overlapping tuples will acquire them in the same
      # order regardless of how their `target_tuples` is written. `pg_advisory_xact_lock`
      # is reentrant and releases at commit/rollback.
      def acquire_advisory_locks(tuples)
        return if tuples.empty?

        resolved = tuples.map do |book_ref, gid, currency|
          book_id = book_ref.is_a?(Integer) ? book_ref : ::Stern.chart.book_code(book_ref)
          raise ArgumentError, "unknown book #{book_ref.inspect}" unless book_id

          [ book_id, gid, currency ]
        end

        resolved.sort.uniq.each do |book_id, gid, currency|
          ApplicationRecord.advisory_lock(book_id:, gid:, currency:)
        end
      end
    end
  end
end
