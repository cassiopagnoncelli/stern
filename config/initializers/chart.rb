# frozen_string_literal: true

module Stern
  chart_path ||= Engine.root.join("config/chart.yaml").to_s.freeze
  chart_contents ||= YAML.load_file(chart_path)
  STERN_DEFS ||= chart_contents.deep_symbolize_keys!

  TIMESTAMP_DELTA ||= 2 * (1.second / 1e6)

  BOOKS ||= STERN_DEFS[:books].with_indifferent_access.freeze

  ENTRY_PAIRS ||= STERN_DEFS[:entry_pairs].map { |k, v| ["add_#{k}".to_sym, v[:code]] }.to_h.merge(
    STERN_DEFS[:entry_pairs].map { |k, v| ["remove_#{k}".to_sym, -v[:code]] }.to_h
  ).with_indifferent_access.freeze
end
