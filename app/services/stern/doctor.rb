# frozen_string_literal: true

module Stern
  # Read-only audits of ledger consistency. Every method here is side-effect-free.
  # For destructive repair operations see Stern::Repair.
  class Doctor
    def self.amount_consistent?
      amount_inconsistency.nil?
    end

    # Full ledger health check. Returns `nil` when both invariants hold:
    #   1. global `sum(amount) == 0`
    #   2. every `(book_id, gid, currency)` cascade's `ending_balance`
    #      matches the running sum of `amount`
    # On failure returns a tagged detail hash so callers know exactly what
    # broke without re-running the audit:
    #   { kind: :amount_sum, sum: <non-zero> }
    #   { kind: :ending_balance, book_id:, gid:, currency:,
    #     entry_id:, timestamp:, amount:,
    #     expected_ending_balance:, actual_ending_balance: }
    #
    # Cost: O(n_entries) — one full table sum plus one ordered walk per
    # distinct `(book_id, gid, currency)` tuple. Do not call on hot paths.
    def self.first_inconsistency
      amount = amount_inconsistency
      return amount.merge(kind: :amount_sum) if amount

      Entry.distinct.pluck(:book_id, :gid, :currency).each do |book_id, gid, currency|
        detail = first_ending_balance_inconsistency(book_id:, gid:, currency:)
        return detail.merge(kind: :ending_balance, book_id:, gid:, currency:) if detail
      end

      nil
    end

    # Detail companion to `amount_consistent?`. Returns `nil` when the global
    # sum is zero, or `{ sum: <non-zero> }` so callers (specs, log lines) can
    # surface the offending value without re-running the query.
    def self.amount_inconsistency
      sum = Entry.sum(:amount)
      return nil if sum.zero?

      { sum: sum }
    end

    def self.ending_balance_consistent?(book_id:, gid:, currency:)
      first_ending_balance_inconsistency(book_id:, gid:, currency:).nil?
    end

    # Detail companion to `ending_balance_consistent?`. Walks the cascade and
    # returns the first row whose `ending_balance` disagrees with the running
    # sum, or `nil` when the cascade is intact. The walk is identical to the
    # `?` predicate's, so callers that already need the detail on failure pay
    # the same cost — no second pass.
    def self.first_ending_balance_inconsistency(book_id:, gid:, currency:)
      current_ending_balance = 0
      Entry.where(book_id:, gid:, currency:).order(:timestamp).each do |e|
        expected = e.amount + current_ending_balance
        if e.ending_balance != expected
          return {
            entry_id: e.id,
            timestamp: e.timestamp,
            amount: e.amount,
            expected_ending_balance: expected,
            actual_ending_balance: e.ending_balance,
          }
        end

        current_ending_balance += e.amount
      end

      nil
    end

    def self.ending_balances_inconsistencies_across_books(gid:, currency:)
      ::Stern.chart.book_codes.flat_map do |book_id|
        ending_balances_inconsistencies(book_id:, gid:, currency:)
      end
    end

    def self.ending_balances_inconsistencies(book_id:, gid:, currency:) # rubocop:disable Metrics/MethodLength
      sql = %{
        SELECT entry_id
        FROM (
          SELECT
            se.id AS entry_id,
            CASE WHEN ending_balance = checked_ending_balance THEN 0 ELSE 1 END AS inconsistent
          FROM (
            SELECT id, ending_balance
            FROM stern_entries
            WHERE book_id = :book_id AND gid = :gid AND currency = :currency
          ) se
          LEFT JOIN (
            SELECT
              id,
              (SUM(amount) OVER (ORDER BY timestamp)) AS checked_ending_balance
            FROM stern_entries
            WHERE book_id = :book_id AND gid = :gid AND currency = :currency
            ORDER BY timestamp
          ) se2 ON se.id = se2.id
        ) inconsistencies_results
        WHERE inconsistent = 1
      }
      sanitized_sql = ApplicationRecord.sanitize_sql_array([ sql, { book_id:, gid:, currency: } ])
      results = ApplicationRecord.connection.execute(sanitized_sql)
      results.to_a.flatten
    end
  end
end
