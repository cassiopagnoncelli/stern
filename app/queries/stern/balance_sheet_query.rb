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
      self.book_ids = book_ids
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
        WITH previous_balances AS (
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
        GROUP BY book_id
        )
        SELECT
          cb.*,
          COALESCE(pb.previous_balance, 0) AS previous_balance,
          COALESCE(pb.previous_balance, 0) + cb.net AS final_balance
        FROM current_balances cb
        LEFT JOIN previous_balances pb ON cb.book_id = pb.book_id
      }
      ApplicationRecord.sanitize_sql_array([sql, { start_date:, end_date: }])
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
