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

    # @param gid [Bignum] group id, eg. merchant id (optional)
    # @param book_id [DateTime] consolidating book, eg. merchant balance
    # @param start_date [DateTime] report starting date/time
    # @param end_date [DateTime] report ending date/time
    # @param page [Integer] page number (-3, -2, -1, 1, 2, 3, ..., defaults to -1, page 0 does not exist)
    # @param per_page [Integer] records per page (defaults to 50)
    def initialize(book_id:, start_date:, end_date:, gid: nil, page: -1, per_page: 50)
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
        record = record.symbolize_keys.slice(:timestamp, :amount, :ending_balance, :code)
        record[:code] = Stern::ENTRY_PAIRS_CODES[record[:code]].sub(/^add_/, '').sub(/^remove_/, '')
        record
      end

      # If negative page, reverse results to maintain ascending order
      page < 0 ? results_array.reverse : results_array
    end

    def sql
      query = Entry.joins(:entry_pair)
        .select('stern_entries.*, stern_entry_pairs.code')
        .where(book_id:)
        .where("stern_entries.timestamp BETWEEN ? AND ?", start_date, end_date)
      query = query.where(gid:) if gid.present?
      query = paginate(query)

      query.to_sql
    end

    def paginate(query)
      if page.positive?
        query
          .order(:timestamp)
          .limit(per_page)
          .offset((page - 1) * per_page)
      else
        # Negative pages: descending order for reverse pagination
        absolute_page = page.abs
        query
          .order(timestamp: :desc)
          .limit(per_page)
          .offset((absolute_page - 1) * per_page)
      end
    end
  end
end

__END__

# Examples:

EntriesQuery.new(
  book_id: :customer_balance_available_usd,
  start_date: DateTime.current.yesterday,
  end_date: DateTime.current + 1.minute,
  gid: 1
).call

# Get last page (default behavior)
EntriesQuery.new(
  book_id: :merchant_balance,
  start_date: DateTime.parse('2025-05-01 00:00:00'),
  end_date: DateTime.current,
  gid: 1101
).call

# Get first page with 25 records per page
EntriesQuery.new(
  book_id: :merchant_balance,
  start_date: DateTime.parse('2025-05-01 00:00:00'),
  end_date: DateTime.current,
  gid: 1101,
  page: 1,
  per_page: 25
).call

# Get second-to-last page with 100 records per page
EntriesQuery.new(
  book_id: :merchant_balance,
  start_date: DateTime.parse('2025-05-01 00:00:00'),
  end_date: DateTime.current,
  gid: 1101,
  page: -2,
  per_page: 100
).call

# Get entries for all gids in a book
EntriesQuery.new(
  book_id: :merchant_balance,
  start_date: DateTime.parse('2025-05-01 00:00:00'),
  end_date: DateTime.current
).call
