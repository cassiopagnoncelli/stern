module Stern
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    establish_connection "stern_#{Rails.env}".to_sym

    # Acquires an EXCLUSIVE lock on `table` for the duration of the current transaction.
    # Serializes concurrent writers on that table so the cascading `ending_balance`
    # computation in `create_entry` cannot observe a pre-commit read of another writer.
    # Allows concurrent readers (SELECT acquires ACCESS SHARE, which EXCLUSIVE permits).
    def self.lock_table(table:)
      connection.execute("LOCK TABLE #{table.strip} IN EXCLUSIVE MODE;")
    end

    # SQL fragment that derives the bigint advisory lock key for a
    # `(book_id, gid, currency)` tuple. Delegates to the `stern_advisory_lock_key`
    # SQL function, which is the single definition every writer shares —
    # `BaseOperation#acquire_advisory_locks` (via `advisory_lock`),
    # `Stern::Repair` (via `advisory_lock`), `create_entry` v03, and
    # `destroy_entry` v03. Inline the fragment when you need the key
    # alongside other SQL (e.g. tests holding a lock from a raw connection)
    # so you don't reconstruct the formula.
    ADVISORY_LOCK_KEY_FRAGMENT = "stern_advisory_lock_key(?, ?, ?)".freeze

    # Acquires a Postgres transaction-scoped advisory lock keyed on
    # (book_id, gid, currency). Every writer that touches the tuple — operations
    # (via BaseOperation#acquire_advisory_locks), direct Entry.create! (via
    # create_entry v03), and Stern::Repair rebuilds — must call this so
    # concurrent writers serialize cleanly. Reentrant within a transaction.
    # Must be called inside an open transaction.
    def self.advisory_lock(book_id:, gid:, currency:)
      connection.execute(
        sanitize_sql_array([
          "SELECT pg_advisory_xact_lock(#{ADVISORY_LOCK_KEY_FRAGMENT})",
          book_id, gid, currency
        ]),
      )
    end
  end
end
