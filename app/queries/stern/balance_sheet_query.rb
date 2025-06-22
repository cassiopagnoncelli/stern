# frozen_string_literal: true

module Stern
  # Returns a balance sheet for a given time period.
  #
  # Example at the end of the file.
  # 
  class BalanceSheetQuery < BaseQuery
    attr_accessor :start_date, :end_date, :book_format, :book_ids

    # @param start_date [DateTime] report starting date/time
    # @param end_date [DateTime] report ending date/time
    # @param book_ids [Array<Bignum>] book ids, eg. %i[customer_balance_available_usd merchant_balance_available_usd]
    # @param book_format [Array<Symbol>] format of the code, eg. %i[titleize]
    def initialize(start_date:, end_date:, book_ids: BOOKS.values, book_format: %i[titleize])
      self.start_date = Helpers::NormalizeTimeHelper.normalize_time(start_date, true)
      self.end_date = Helpers::NormalizeTimeHelper.normalize_time(end_date, true)
      self.book_format = book_format
      self.book_ids = book_ids.map { |book_id| (book_id.is_a?(Symbol) || book_id.is_a?(String)) ? BOOKS[book_id] : book_id }
      raise ArgumentError, "book does not exist" if (self.book_ids - BOOKS.values).any?
    end

    def call
      @results = execute_query
      @results.map do |record|
        record = record.symbolize_keys
        record[:book_name] = book_format.reduce(BOOKS_CODES[record[:book_id]]) do |acc, format|
          Helpers::StringFormatHelper.format_string(acc, format)
        end
        record
      end
    end

    def sql
      sql = %{
        WITH books AS (
          SELECT unnest(ARRAY[:book_ids]) AS book_id
        ),
        previous_balances AS (
          SELECT
            book_id,
            SUM(ending_balance) AS previous_balance
          FROM (
            SELECT
              DISTINCT ON (gid) gid,
              book_id,
              FIRST_VALUE(ending_balance) OVER (
                PARTITION BY gid, book_id ORDER BY timestamp DESC
              ) AS ending_balance
            FROM stern_entries
            WHERE timestamp < :start_date
          ) ending_balances
          WHERE book_id IN (:book_ids)
          GROUP BY book_id
        ),
        current_balances AS (
          SELECT
            book_id,
            SUM(CASE WHEN amount < 0 THEN amount ELSE 0 END) AS debts,
            SUM(CASE WHEN amount > 0 THEN amount ELSE 0 END) AS credits,
            SUM(amount) AS net
          FROM stern_entries
          WHERE timestamp BETWEEN :start_date AND :end_date
          AND book_id IN (:book_ids)
          GROUP BY book_id
        )
        SELECT
          b.book_id,
          COALESCE(cb.debts, 0) AS debts,
          COALESCE(cb.credits, 0) AS credits,
          COALESCE(cb.net, 0) AS net,
          COALESCE(pb.previous_balance, 0) AS previous_balance,
          COALESCE(pb.previous_balance, 0) + COALESCE(cb.net, 0) AS final_balance
        FROM books b
        LEFT JOIN current_balances cb ON b.book_id = cb.book_id
        LEFT JOIN previous_balances pb ON b.book_id = pb.book_id
        ORDER BY b.book_id
      }
      ApplicationRecord.sanitize_sql_array([sql, { start_date:, end_date:, book_ids: }])
    end
  end
end

__END__

# Examples:

BalanceSheetQuery.new(
  start_date: DateTime.current.yesterday,
  end_date: DateTime.current + 1.minute,
  book_ids: %i[customer_balance_available_usd bops_pl_usd],
  book_format: %i[titleize]
).call
