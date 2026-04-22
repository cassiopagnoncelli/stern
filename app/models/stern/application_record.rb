module Stern
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    establish_connection "stern_#{Rails.env}".to_sym

    # Generates an unique gid to be used across entries, entry_pairs, and operations.
    def self.generate_gid
      connection.execute("SELECT nextval('gid_seq')").first.values.first
    end

    # Acquires an EXCLUSIVE lock on `table` for the duration of the current transaction.
    # Serializes concurrent writers on that table so the cascading `ending_balance`
    # computation in `create_entry` cannot observe a pre-commit read of another writer.
    # Allows concurrent readers (SELECT acquires ACCESS SHARE, which EXCLUSIVE permits).
    def self.lock_table(table:)
      connection.execute("LOCK TABLE #{table.strip} IN EXCLUSIVE MODE;")
    end

    # Acquires a Postgres transaction-scoped advisory lock keyed on
    # (book_id, gid, currency). Every writer that touches the tuple — operations
    # (via BaseOperation#acquire_advisory_locks), direct Entry.create! (via
    # create_entry v03), and Stern::Repair rebuilds — must call this so
    # concurrent writers serialize cleanly. Reentrant within a transaction.
    # Must be called inside an open transaction.
    def self.advisory_lock(book_id:, gid:, currency:)
      connection.execute(
        sanitize_sql_array([
          "SELECT pg_advisory_xact_lock(hashtextextended(format('stern:%s:%s:%s', ?, ?, ?), 0))",
          book_id, gid, currency
        ]),
      )
    end
  end
end
