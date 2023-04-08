# frozen_string_literal: true

module Stern
  # Sum up the ending balances across all accounts (gid) at the given timestamp.
  # This is equivalent to sum all individual BalanceQuery on the book_id.
  class OutstandingBalanceQuery < BaseQuery
    attr_accessor :book_id, :timestamp, :results

    # @param book_id [Bignum] book, eg. merchant balance
    # @param timestamp [DateTime] balance at the given time
    def initialize(book_id:, timestamp: DateTime.current)
      raise ArgumentError, "book does not exist" unless book_id.to_s.in?(BOOKS.keys) || book_id.in?(BOOKS.values)
      raise ArgumentError, "should be Date or DateTime" unless timestamp.is_a?(Date) || timestamp.is_a?(DateTime)

      self.book_id = book_id.is_a?(Symbol) || book_id.is_a?(String) ? BOOKS[book_id] : book_id
      self.timestamp = Helpers::NormalizeTimeHelper.normalize_time(timestamp, true)
    end

    def call
      @results = execute_query
      @results.first['outstanding'].to_i
    end

    def execute_query
      ApplicationRecord.connection.execute(sql)
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
          WHERE book_id = :book_id AND timestamp <= :timestamp
        ) ending_balances
      }
      ApplicationRecord.sanitize_sql_array([sql, {book_id:, timestamp:}])
    end
  end
end
