module Stern
  module LedgerHelper
    def format_currency_value(value, decimal_places = 2)
      return number_to_currency(0, unit: "", precision: decimal_places) if value.nil?

      divisor = 10 ** decimal_places
      number_to_currency(value.to_f / divisor, unit: "", precision: decimal_places)
    end

    # Dropdown / picker label combining the ISO ticker with its localized name
    # and (when distinct) the rendering symbol — e.g. "BRL — Real (R$)" or
    # "USDT — Tether USD" (symbol omitted because it equals the ticker).
    def currency_display_label(name)
      display = ::Stern.currencies.display_name(name)
      symbol  = ::Stern.currencies.symbol(name)
      return name.to_s if display.blank?

      label = "#{name} — #{display}"
      label += " (#{symbol})" if symbol.present? && symbol != name.to_s
      label
    end
  end
end
