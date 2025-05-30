# frozen_string_literal: true

chart_of_accounts_path = File.expand_path("../../chart_of_accounts.yml", __FILE__).freeze
STERN_DEFS = YAML.load_file(chart_of_accounts_path).deep_symbolize_keys!

module Stern
  TIMESTAMP_DELTA = 2 * (1.second / 1e6)

  BOOKS = STERN_DEFS[:books].with_indifferent_access.freeze

  ENTRY_PAIRS = STERN_DEFS[:entry_pairs].map { |k, v| ["add_#{k}".to_sym, v[:code]] }.to_h.merge(
    STERN_DEFS[:entry_pairs].map { |k, v| ["remove_#{k}".to_sym, -v[:code]] }.to_h
  ).with_indifferent_access.freeze
end
