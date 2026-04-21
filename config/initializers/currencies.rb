# frozen_string_literal: true

module Stern
  _currencies_catalog = YAML.load_file(Engine.root.join("config/currencies_catalog.yaml"))

  STERN_CURRENCIES ||= _currencies_catalog.freeze

  STERN_CURRENCIES_R ||= _currencies_catalog
    .each_with_object({}) { |(name, idx), h| h[idx] = name if h[idx].nil? || name == name.upcase }
    .freeze
end
