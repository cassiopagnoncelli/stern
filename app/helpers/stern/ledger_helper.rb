module Stern
  module LedgerHelper
    def format_currency_value(value, decimal_places = 2)
      return number_to_currency(0, unit: "", precision: decimal_places) if value.nil?

      divisor = 10 ** decimal_places
      number_to_currency(value.to_f / divisor, unit: "", precision: decimal_places)
    end
  end
end
