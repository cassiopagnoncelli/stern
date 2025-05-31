# frozen_string_literal: true

module Stern
  # Get the book's balance at the given timestamp for all accounts (gids).
  #
  # For instance, in merchant book, this would return all merchant balances at the given time.
  #
  # Examples at the end of the file.
  #
  class BalancesQuery < BaseQuery
    attr_accessor :book_id, :timestamp, :results

    # @param book_id [Bignum] book, eg. merchant balance
    # @param timestamp [DateTime] balance at the given time
    def initialize(book_id:, timestamp: DateTime.current)
      unless book_id.to_s.in?(BOOKS.keys) || book_id.in?(BOOKS.values)
        raise ArgumentError,
              "book does not exist"
      end
      unless timestamp.is_a?(Date) || timestamp.is_a?(DateTime)
        raise ArgumentError,
              "should be Date or DateTime"
      end

      self.book_id = book_id.is_a?(Symbol) || book_id.is_a?(String) ? BOOKS[book_id] : book_id
      self.timestamp = Helpers::NormalizeTimeHelper.normalize_time(timestamp, true)
    end

    def call
      @results = execute_query
      @results.values.to_h
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
      ApplicationRecord.sanitize_sql_array([sql, { book_id:, timestamp: }])
    end
  end
end

__END__

BalancesQuery.new(book_id: 1101).call
