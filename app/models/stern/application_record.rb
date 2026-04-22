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
  end
end
