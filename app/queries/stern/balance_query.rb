# frozen_string_literal: true

module Stern
  # Get the book's balance at the given timestamp.
  # For instance, in merchant book, this would return the merchant balance at the given time.
  #
  # Returns balance as a bigint.
  #
  # Examples at the end of the file.
  #
  class BalanceQuery < BaseQuery
    attr_accessor :gid, :book_id, :currency, :timestamp, :results

    # @param gid [Bignum] group id, eg. merchant id
    # @param book_id [Bignum] book id
    # @param currency [String, Symbol, Integer] currency name or index
    # @param timestamp [Date, Time, DateTime] balance at the given time
    def initialize(gid:, book_id:, currency:, timestamp:)
      unless timestamp.is_a?(Date) || timestamp.is_a?(Time) || timestamp.is_a?(DateTime)
        raise ArgumentError, "should be Date, Time, or DateTime"
      end

      self.gid = gid
      self.book_id = resolve_book_id!(book_id)
      self.currency = resolve_currency!(currency)
      self.timestamp = Helpers::NormalizeTimeHelper.normalize_time(timestamp, true)
    end

    def call
      @results = execute_query
      @results.first&.ending_balance || 0
    end

    def execute_query
      Entry.last_entry(book_id, gid, currency, timestamp)
    end
  end
end

__END__

BalanceQuery.new(
  gid: 1101,
  book_id: :merchant_balance,
  currency: :BRL,
  timestamp: DateTime.current
).call
