# frozen_string_literal: true

module Stern
  module Helpers
    module FrequencyHelper
      def self.frequency_in_sql(param)
        case param
        when :hourly
          'HOUR'
        when :daily
          'DAY'
        when :weekly
          'WEEK'
        when :monthly
          'MONTH'
        when :yearly
          'YEAR'
        else
          raise ArgumentError, "invalid grouping date precision error"
        end
      end
    end
  end
end
