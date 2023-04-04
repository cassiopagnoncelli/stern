module Stern
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    establish_connection "stern_#{Rails.env}".to_sym

    # Generates an unique gid to be used across operations, txs, and entries.
    def self.generate_gid
      connection.execute("SELECT nextval('gid_seq')").first.values.first
    end
  end
end
