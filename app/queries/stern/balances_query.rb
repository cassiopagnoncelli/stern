# frozen_string_literal: true

module Stern
  # Get the book's balance at the given timestamp for all accounts (gids).
  #
  # For instance, in merchant book, this would return all merchant balances at the given time.
  class BalancesQuery < BaseQuery
    attr_accessor :book_id, :timestamp, :results

    # @param gid [Bignum] group id, eg. merchant id
    # @param timestamp [DateTime] balance at the given time
    def initialize(book_id:, timestamp: DateTime.current)
      raise ArgumentError, "book does not exist" unless book_id.to_s.in?(BOOKS.keys) || book_id.in?(BOOKS.values)
      raise ArgumentError, "should be Date or DateTime" unless timestamp.is_a?(Date) || timestamp.is_a?(DateTime)

      self.book_id = book_id.is_a?(Symbol) || book_id.is_a?(String) ? BOOKS[book_id] : book_id
      self.timestamp = Helpers::NormalizeTimeHelper.normalize_time(timestamp, true)
    end

    def call
      @results = execute_query
      @results.values.to_h
    end

    def execute_query
      ActiveRecord::Base.connection.execute(sql)
    end

    def sql
      sql = %{
        SELECT
          DISTINCT ON (gid) gid,
          FIRST_VALUE(ending_balance) OVER (
            PARTITION BY gid ORDER BY timestamp DESC
          ) AS ending_balance
        FROM stern_entries
        WHERE book_id = :book_id AND timestamp <= :timestamp
      }
      ActiveRecord::Base.sanitize_sql_array([sql, {book_id:, timestamp:}])      
    end
  end
end
