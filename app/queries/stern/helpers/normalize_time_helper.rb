# frozen_string_literal: true

module Stern
  module Helpers
    module NormalizeTimeHelper
      def self.normalize_time(dt, past_eod)
        raise InvalidTimeError unless dt.is_a?(Date) || dt.is_a?(Time) || dt.is_a?(DateTime)

        t = dt.is_a?(DateTime) ? dt : dt.to_datetime
        return t unless past_eod

        t.to_date >= Date.current ? t : t.end_of_day.to_datetime
      end

      # def self.normalize_time(dt, past_eod)
      #   raise InvalidTimeError unless dt.is_a?(Date) || dt.is_a?(Time) || dt.is_a?(DateTime)
  
      #   t = dt.is_a?(DateTime) ? dt : dt.to_datetime
      #   t.to_date >= Date.current || past_eod ? t.end_of_day.to_datetime : t
      # end
    end
  end
end
