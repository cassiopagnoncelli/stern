# frozen_string_literal: true

module Stern
  _raw = YAML.load_file(Engine.root.join("config/currencies_catalog.yaml"))

  STERN_CURRENCIES ||= _raw.freeze

  STERN_CURRENCIES_R ||= _raw
    .each_with_object({}) { |(name, idx), h| h[idx] = name if h[idx].nil? || name == name.upcase }
    .freeze
end
