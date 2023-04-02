# frozen_string_literal: true

module Stern
  # Get the book's balance at the given timestamp.
  #
  # For instance, in merchant book, this would return the merchant balance at the given time.
  class BalanceQuery < BaseQuery
    attr_accessor :gid, :book_id, :timestamp, :results

    # @param gid [Bignum] group id, eg. merchant id
    # @param book_id [Bignum] book id
    # @param timestamp [DateTime] balance at the given time
    def initialize(gid:, book_id:, timestamp:)
      raise BookDoesNotExistError unless book_id.to_s.in?(BOOKS.keys) || book_id.in?(BOOKS.values)
      raise ShouldBeDateOrTimestampError unless timestamp.is_a?(Date) || timestamp.is_a?(DateTime)

      self.gid = gid
      self.book_id = book_id.is_a?(Symbol) || book_id.is_a?(String) ? BOOKS[book_id] : book_id
      self.timestamp = Helpers::NormalizeTimeHelper.normalize_time(timestamp, true)
    end

    def call
      @results = execute_query
      @results.first&.ending_balance || 0
    end

    def execute_query
      Entry.last_entry(book_id, gid, timestamp)
    end
  end
end
