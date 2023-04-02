module Stern
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    def self.inherited(subclass)
      super
      # subclass.table_name = ... # rename table
    end

    # Generates an unique gid to be used across operations, txs, and entries.
    def self.generate_gid
      ActiveRecord::Base.connection.execute("SELECT nextval('gid_seq')").first.values.first
    end
  end
end
