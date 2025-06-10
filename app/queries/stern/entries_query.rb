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
    attr_accessor :gid, :book_id, :start_date, :end_date, :page, :per_page, :results

    # @param gid [Bignum] group id, eg. merchant id
    # @param book_id [DateTime] consolidating book, eg. merchant balance
    # @param start_date [DateTime] report starting date/time
    # @param end_date [DateTime] report ending date/time
    # @param page [Integer] page number (-3, -2, -1, 1, 2, 3, ..., defaults to -1, page 0 does not exist)
    # @param per_page [Integer] records per page (defaults to 50)
    def initialize(gid:, book_id:, start_date:, end_date:, page: -1, per_page: 50)
      unless book_id.to_s.in?(BOOKS.keys) || book_id.in?(BOOKS.values)
        raise ArgumentError, "book does not exist"
      end

      raise ArgumentError, "page cannot be 0" if page == 0
      raise ArgumentError, "per_page must be positive" if per_page <= 0

      self.gid = gid
      self.book_id = book_id.is_a?(Symbol) || book_id.is_a?(String) ? BOOKS[book_id] : book_id
      self.start_date = Helpers::NormalizeTimeHelper.normalize_time(start_date, true)
      self.end_date = Helpers::NormalizeTimeHelper.normalize_time(end_date, true)
      self.page = page
      self.per_page = per_page
    end

    def call
      @results = execute_query
      results_array = @results.map do |record|
        record.symbolize_keys.slice(:timestamp, :amount, :ending_balance)
      end
      
      # If negative page, reverse results to maintain ascending order
      page < 0 ? results_array.reverse : results_array
    end

    def sql
      query = Entry
        .where(gid:, book_id:)
        .where("timestamp BETWEEN ? AND ?", start_date, end_date)
      
      if page > 0
        # Positive pages: ascending order with normal pagination
        query = query
          .order(:timestamp)
          .limit(per_page)
          .offset((page - 1) * per_page)
      else
        # Negative pages: descending order for reverse pagination
        absolute_page = page.abs
        query = query
          .order(timestamp: :desc)
          .limit(per_page)
          .offset((absolute_page - 1) * per_page)
      end
      
      query.to_sql
    end
  end
end

__END__

# Examples:

# Get last page (default behavior)
EntriesQuery.new(
  gid: 1101,
  book_id: :merchant_balance,
  start_date: DateTime.parse('2025-05-01 00:00:00'),
  end_date: DateTime.current
).call

# Get first page with 25 records per page
EntriesQuery.new(
  gid: 1101,
  book_id: :merchant_balance,
  start_date: DateTime.parse('2025-05-01 00:00:00'),
  end_date: DateTime.current,
  page: 1,
  per_page: 25
).call

# Get second-to-last page with 100 records per page
EntriesQuery.new(
  gid: 1101,
  book_id: :merchant_balance,
  start_date: DateTime.parse('2025-05-01 00:00:00'),
  end_date: DateTime.current,
  page: -2,
  per_page: 100
).call
