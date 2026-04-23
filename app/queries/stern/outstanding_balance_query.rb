# frozen_string_literal: true

module Stern
  # Sum up the ending balances across all accounts (gid) at the given timestamp.
  # This is equivalent to sum all individual BalanceQuery on the book_id.
  #
  # Returns balance as a bigint.
  #
  # Example at the end of the file.
  #
  class OutstandingBalanceQuery < BaseQuery
    attr_accessor :book_id, :currency, :timestamp, :results

    # @param book_id [Bignum] book, eg. merchant balance
    # @param currency [String, Symbol, Integer] currency name or index
    # @param timestamp [Date, Time, DateTime] balance at the given time
    def initialize(book_id:, currency:, timestamp: DateTime.current)
      unless timestamp.is_a?(Date) || timestamp.is_a?(Time) || timestamp.is_a?(DateTime)
        raise ArgumentError, "should be Date, Time, or DateTime"
      end

      self.book_id = resolve_book_id!(book_id)
      self.currency = resolve_currency!(currency)
      self.timestamp = Helpers::NormalizeTimeHelper.normalize_time(timestamp, true)
    end

    def call
      @results = execute_query
      @results.first["outstanding"].to_i
    end

    def sql
      sql = %{
        SELECT
          SUM(ending_balance) AS outstanding
        FROM (
          SELECT
            DISTINCT ON (gid) gid,
            FIRST_VALUE(ending_balance) OVER (
              PARTITION BY gid ORDER BY timestamp DESC
            ) AS ending_balance
          FROM stern_entries
          WHERE book_id = :book_id AND currency = :currency AND timestamp <= :timestamp
        ) ending_balances
      }
      ApplicationRecord.sanitize_sql_array([ sql, { book_id:, currency:, timestamp: } ])
    end
  end
end

__END__

OutstandingBalanceQuery.new(book_id: :merchant_balance, currency: :BRL).call
