# frozen_string_literal: true

module Stern
  # Sums all transactions over a time window for an account (gid) in a book (eg. merchant
  # balance). No ending balance or previous balance is provided.
  #
  # Returns an array of entry dictionaries in the format: timestamp, amount, ending_balance.
  #
  # Example at the end of the file.
  # 
  class EntriesQuery < BaseQuery
    attr_accessor :gid, :book_id, :start_date, :end_date, :results

    # @param gid [Bignum] group id, eg. merchant id
    # @param book_id [DateTime] consolidating book, eg. merchant balance
    # @param start_date [DateTime] report starting date/time
    # @param end_date [DateTime] report ending date/time
    def initialize(gid:, book_id:, start_date:, end_date:)
      unless book_id.to_s.in?(BOOKS.keys) || book_id.in?(BOOKS.values)
        raise ArgumentError, "book does not exist"
      end

      self.gid = gid
      self.book_id = book_id.is_a?(Symbol) || book_id.is_a?(String) ? BOOKS[book_id] : book_id
      self.start_date = Helpers::NormalizeTimeHelper.normalize_time(start_date, true)
      self.end_date = Helpers::NormalizeTimeHelper.normalize_time(end_date, true)
    end

    def call
      @results = execute_query
      @results.map do |record|
        {
          timestamp: record[:timestamp],
          amount: record[:amount],
          ending_balance: record[:ending_balance]
        }
      end
    end

    def sql
      Entry
        .where(gid:, book_id:)
        .where("entries.timestamp BETWEEN ? AND ?", start_date, end_date)
        .order(:timestamp)
    end
  end
end

__END__

EntriesQuery.new(
  gid: 1101,
  book_id: :boleto,
  start_date: DateTime.current.last_month.beginning_of_month,
  end_date: DateTime.current
).call
