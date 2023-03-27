module Stern
  class Base < ActiveRecord::Base
    self.abstract_class = true
    establish_connection "stern_#{Rails.env}".to_sym

    def self.inherited(subclass)
      super
      # subclass.table_name = ... # rename table
    end
  end
end
