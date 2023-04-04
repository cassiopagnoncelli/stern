# frozen_string_literal: true

module Stern
  # Consolidates all transactions during a time window for an account (gid) in a book (eg. merchant
  # balance).
  class ConsolidatedEntriesQuery < BaseQuery
    attr_accessor :gid, :book_id, :time_grouping, :start_date, :end_date, :results

    # @param gid [Bignum] group id, eg. merchant id
    # @param book_id [DateTime] consolidating book, eg. merchant balance
    # @param time_grouping [Symbol] bins to consolidate time, from :hourly to :yearly
    # @param start_date [DateTime] report starting date/time
    # @param end_date [DateTime] report ending date/time
    def initialize(gid:, book_id:, time_grouping:, start_date:, end_date:)
      raise ArgumentError, "book does not exist" unless book_id.to_s.in?(BOOKS.keys) || book_id.in?(BOOKS.values)

      self.gid = gid
      self.book_id = book_id.is_a?(Symbol) || book_id.is_a?(String) ? BOOKS[book_id] : book_id
      self.time_grouping = Helpers::FrequencyHelper.frequency_in_sql(time_grouping)
      self.start_date = Helpers::NormalizeTimeHelper.normalize_time(start_date, true)
      self.end_date = Helpers::NormalizeTimeHelper.normalize_time(end_date, true)
    end

    def call
      @results = execute_query
      @results.map do |record|
        record['code'] = TXS.invert[record['code']]
        record['time_window'] = record['time_window'].in_time_zone.to_datetime
        record
      end
    end

    def execute_query
      ApplicationRecord.connection.execute(sql)
    end

    def sql
      sql = %{
        SELECT
          DATE_TRUNC(:time_grouping, txs.timestamp) AS time_window,
          txs.code,
          SUM(txs.amount) AS amount
        FROM stern_entries es
        JOIN stern_txs txs ON es.tx_id = txs.id
        WHERE
          gid = :gid
          AND es.book_id = :book_id
          AND (txs.timestamp BETWEEN :start_date AND :end_date)
        GROUP BY time_window, code
        ORDER BY time_window, code
      }
      ApplicationRecord.sanitize_sql_array([sql,
        { time_grouping:, gid:, book_id:, start_date:, end_date: }
      ])
    end
  end
end
