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
    attr_accessor :gid, :book_id, :start_date, :end_date, :code_format, :page, :per_page, :results

    # @param gid [Bignum] group id, eg. merchant id (optional)
    # @param book_id [DateTime] consolidating book, eg. merchant balance
    # @param start_date [DateTime] report starting date/time
    # @param end_date [DateTime] report ending date/time
    # @param code_format [Array<Symbol>] format of the code, eg. %i[titleize drop_first_word]
    # @param page [Integer] page number (-3, -2, -1, 1, 2, 3, ..., defaults to -1, page 0 does not exist)
    # @param per_page [Integer] records per page (defaults to 50)
    def initialize(book_id:, start_date:, end_date:, gid: nil, code_format: %i[titleize drop_first_word], page: -1, per_page: 50)
      unless book_id.to_s.in?(BOOKS.keys) || book_id.in?(BOOKS.values)
        raise ArgumentError, "book does not exist"
      end

      raise ArgumentError, "page cannot be 0" if page == 0
      raise ArgumentError, "per_page must be positive" if per_page <= 0

      self.gid = gid
      self.book_id = book_id.is_a?(Symbol) || book_id.is_a?(String) ? BOOKS[book_id] : book_id
      self.start_date = Helpers::NormalizeTimeHelper.normalize_time(start_date, true)
      self.end_date = Helpers::NormalizeTimeHelper.normalize_time(end_date, true)
      self.code_format = code_format
      self.page = page
      self.per_page = per_page
    end

    def call
      @results = execute_query
      results_array = @results.map do |record|
        record = record.symbolize_keys.slice(:timestamp, :gid, :amount, :ending_balance, :code)
        record[:code] = code_format.reduce(ENTRY_PAIRS_CODES[record[:code]]) do |acc, format|
          Helpers::StringFormatHelper.format_string(acc, format)
        end
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
  gid: 1,
  code_format: %i[titleize drop_first_word]
).call
