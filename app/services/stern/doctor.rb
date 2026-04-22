# frozen_string_literal: true

module Stern
  # Read-only audits of ledger consistency. Every method here is side-effect-free.
  # For destructive repair operations see Stern::Repair.
  class Doctor
    def self.consistent?
      amount_consistent?
    end

    def self.amount_consistent?
      Entry.sum(:amount).zero?
    end

    def self.ending_balance_consistent?(book_id:, gid:, currency:)
      current_ending_balance = 0
      Entry.where(book_id:, gid:, currency:).order(:timestamp).each do |e|
        return false unless e.ending_balance == e.amount + current_ending_balance

        current_ending_balance += e.amount
      end

      true
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
