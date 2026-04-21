# frozen_string_literal: true

module Stern
  STERN_CURRENCIES ||= YAML.load_file(Engine.root.join("config/currencies_catalog.yaml")).freeze

  STERN_CURRENCIES_R ||= STERN_CURRENCIES
    .each_with_object({}) { |(name, idx), h| h[idx] = name if h[idx].nil? || name == name.upcase }
    .freeze
end
