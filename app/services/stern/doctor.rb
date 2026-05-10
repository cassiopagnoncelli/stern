# frozen_string_literal: true

module Stern
  # Read-only audits of ledger consistency. Every method here is side-effect-free.
  # For destructive repair operations see Stern::Repair.
  class Doctor
    def self.amount_consistent?
      amount_inconsistency.nil?
    end

    # Full ledger health check. Returns `nil` when all invariants hold:
    #   1. global `sum(amount) == 0`
    #   2. for every declared book X, `sum(book = X) + sum(book = X_0) == 0`
    #      per currency (companion-parity invariant)
    #   3. every `(book_id, gid, currency)` cascade's `ending_balance`
    #      matches the running sum of `amount`
    # On failure returns a tagged detail hash so callers know exactly what
    # broke without re-running the audit:
    #   { kind: :amount_sum, sum: <non-zero> }
    #   { kind: :companion_parity, book:, companion:, currency:, sum: <non-zero> }
    #   { kind: :unknown_book, book_id:, currency:, sum: }
    #   { kind: :ending_balance, book_id:, gid:, currency:,
    #     entry_id:, timestamp:, amount:,
    #     expected_ending_balance:, actual_ending_balance: }
    #
    # Cost: O(n_entries) — one full table sum, one full GROUP BY scan, plus
    # one ordered walk per distinct `(book_id, gid, currency)` tuple. Do not
    # call on hot paths.
    def self.first_inconsistency
      amount = amount_inconsistency
      return amount.merge(kind: :amount_sum) if amount

      parity = first_companion_parity_inconsistency
      if parity
        kind = parity.key?(:companion) ? :companion_parity : :unknown_book
        return parity.merge(kind: kind)
      end

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

    def self.companion_parity_consistent?
      first_companion_parity_inconsistency.nil?
    end

    # Per-pair audit. For every declared book X (i.e. every book in the
    # active chart that is not itself a `_0` companion), verifies the
    # invariant
    #
    #   sum(entries where book = X, currency = c) +
    #   sum(entries where book = X_0, currency = c) == 0
    #
    # for every currency `c` that appears for either side. The companion
    # `<X>_0` is auto-created by the chart loader; every operation writes
    # both legs of an EntryPair so each (declared, companion) pair is
    # expected to mass-balance to zero independently.
    #
    # This is strictly stronger than `amount_consistent?`: a global sum of
    # zero can mask cross-book imbalances that cancel each other out (e.g.
    # book A is +100 vs A_0, book B is -100 vs B_0). The cascade-level
    # `first_ending_balance_inconsistency` walk is per-tuple and would
    # not flag such a break either.
    #
    # Localized at the (book, currency) level — gid is intentionally
    # aggregated over, since pair parity is a book-level invariant. A
    # single bad currency cannot be masked by other currencies summing
    # correctly.
    #
    # Returns:
    #   nil                                                — every pair balances
    #   { unknown_book_id:, book_id:, currency:, sum: }    — entries reference a
    #     `book_id` not in the active chart (chart drift, renamed or removed
    #     book with leftover entries). Surfaced explicitly because it would
    #     otherwise silently exclude rows from the parity scan.
    #   { book:, companion:, sum:, currency: }             — first declared
    #     pair whose per-currency residual is non-zero. Scan order is
    #     alphabetical by book name for determinism.
    #
    # Cost: O(n_entries) — one full GROUP BY scan over `stern_entries`.
    # Comparable to `amount_consistent?`. Not for hot paths.
    def self.first_companion_parity_inconsistency
      declared_books = ::Stern.chart.books.each_value.reject { |b| b.name.end_with?("_0") }
      companion_codes_by_book = declared_books.to_h do |b|
        [ b.code, ::Stern.chart.book_code("#{b.name}_0") ]
      end
      known_codes = (companion_codes_by_book.keys + companion_codes_by_book.values).to_set

      sums = Entry.group(:book_id, :currency).sum(:amount)

      unknown = sums.reject { |(book_id, _cur), _sum| known_codes.include?(book_id) }
      unknown_first = unknown.min_by { |(book_id, currency), _sum| [ book_id, currency ] }
      if unknown_first
        (book_id, currency), sum = unknown_first
        return { unknown_book_id: book_id, book_id: book_id, currency: currency, sum: sum }
      end

      declared_books.sort_by(&:name).each do |book|
        companion_code = companion_codes_by_book.fetch(book.code)
        currencies = sums.keys.filter_map do |(bid, cur)|
          cur if bid == book.code || bid == companion_code
        end.uniq.sort
        currencies.each do |currency|
          residual = (sums[[ book.code, currency ]] || 0) + (sums[[ companion_code, currency ]] || 0)
          next if residual.zero?

          return {
            book: book.name,
            companion: "#{book.name}_0",
            currency: currency,
            sum: residual
          }
        end
      end

      nil
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
            actual_ending_balance: e.ending_balance
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
