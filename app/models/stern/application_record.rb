module Stern
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    def self.inherited(subclass)
      super
      # subclass.table_name = ... # rename table
    end
  end
end
