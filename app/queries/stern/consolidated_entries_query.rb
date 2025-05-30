# frozen_string_literal: true

module Stern
  # Consolidates all transactions during a time window for an account (gid) in a book (eg. merchant
  # balance).
  #
  # > ConsolidatedEntriesQuery.new(gid: 1101, book_id: :merchant_balance, time_grouping: :hourly, start_date: DateTime.current.last_month.beginning_of_month, end_date: Date.current).call
  # 
  class ConsolidatedEntriesQuery < BaseQuery
    attr_accessor :gid, :book_id, :time_grouping, :start_date, :end_date, :results

    # @param gid [Bignum] group id, eg. merchant id
    # @param book_id [DateTime] consolidating book, eg. merchant balance
    # @param time_grouping [Symbol] bins to consolidate time, from :hourly to :yearly
    # @param start_date [DateTime] report starting date/time
    # @param end_date [DateTime] report ending date/time
    def initialize(gid:, book_id:, time_grouping:, start_date:, end_date:)
      unless book_id.to_s.in?(BOOKS.keys) || book_id.in?(BOOKS.values)
        raise ArgumentError,
              "book does not exist"
      end

      self.gid = gid
      self.book_id = book_id.is_a?(Symbol) || book_id.is_a?(String) ? BOOKS[book_id] : book_id
      self.time_grouping = Helpers::FrequencyHelper.frequency_in_sql(time_grouping)
      self.start_date = Helpers::NormalizeTimeHelper.normalize_time(start_date, true)
      self.end_date = Helpers::NormalizeTimeHelper.normalize_time(end_date, true)
    end

    def call
      @results = execute_query
      @results.map do |record|
        record["code"] = ENTRY_PAIRS.invert[record["code"]]
        record["time_window"] = record["time_window"].in_time_zone.to_datetime
        record
      end
    end

    def execute_query
      ApplicationRecord.connection.execute(sql)
    end

    def sql
      sql = %{
        SELECT
          DATE_TRUNC(:time_grouping, entry_pairs.timestamp) AS time_window,
          entry_pairs.code,
          SUM(entry_pairs.amount) AS amount
        FROM stern_entries es
        JOIN stern_entry_pairs entry_pairs ON es.entry_pair_id = entry_pairs.id
        WHERE
          gid = :gid
          AND es.book_id = :book_id
          AND (entry_pairs.timestamp BETWEEN :start_date AND :end_date)
        GROUP BY time_window, code
        ORDER BY time_window, code
      }
      ApplicationRecord.sanitize_sql_array([sql,
                                            { time_grouping:, gid:, book_id:, start_date:,
                                              end_date:, },])
    end
  end
end
