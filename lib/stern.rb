require "stern/version"
require "stern/engine"

module Stern
  def self.outstanding_balance(book_id = :merchant_balance, timestamp = DateTime.current)
    raise BookDoesNotExistError unless book_id.to_s.in?(BOOKS.keys) || book_id.in?(BOOKS.values)
    raise ShouldBeDateOrTimestampError unless timestamp.is_a?(DateTime)

    book_id = book_id.is_a?(Symbol) || book_id.is_a?(String) ? BOOKS[book_id] : book_id
    timestamp = timestamp.is_a?(Date) ? timestamp.to_time.end_of_day : timestamp

    sql = %{
      SELECT
        SUM(ending_balance) AS outstanding
      FROM (
        SELECT
          DISTINCT ON (gid) gid,
          FIRST_VALUE(ending_balance) OVER (
            PARTITION BY gid ORDER BY timestamp DESC
          ) AS ending_balance
        FROM stern_entries
        WHERE book_id = :book_id AND timestamp <= :timestamp
      ) x
    }
    sanitized_sql = ActiveRecord::Base.sanitize_sql_array([sql, {book_id:, timestamp:}])
    results = ActiveRecord::Base.connection.execute(sanitized_sql)

    results.first['outstanding'] || 0
  end

  def self.balance(gid, book_id = :merchant_balance, timestamp = DateTime.current)
    raise BookDoesNotExistError unless book_id.to_s.in?(BOOKS.keys) || book_id.in?(BOOKS.values)
    raise ShouldBeDateOrTimestampError unless timestamp.is_a?(Date) || timestamp.is_a?(Time)

    book_id = book_id.is_a?(Symbol) || book_id.is_a?(String) ? BOOKS[book_id] : book_id
    ts = normalize_time(timestamp, true)

    e = Entry.last_entry(book_id, gid, ts).first
    e&.ending_balance || 0
  end

  def self.normalize_time(dt, past_eod)
    raise InvalidTimeError unless dt.is_a?(Date) || dt.is_a?(Time) || dt.is_a?(DateTime)

    t = dt.is_a?(DateTime) ? dt : dt.to_datetime
    return t unless past_eod

    t.to_date >= Date.current ? t : t.end_of_day.to_datetime
  end
end
