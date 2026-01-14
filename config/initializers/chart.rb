# frozen_string_literal: true

module Stern
  # Loading chart.
  available_charts = Dir[Engine.root.join("config/charts/*")].map { |file| file.split("/").last.split(".").first }
  chart_name = ENV.fetch("STERN_CHART", "pred")
  unless chart_name.in?(available_charts)
    raise "STERN_CHART=\"#{chart_name}\" should be either of #{available_charts}"
  end
  chart_path ||= Engine.root.join("config/charts/#{chart_name}.yaml").to_s.freeze
  chart_contents ||= YAML.load_file(chart_path)

  # Parse chart.
  STERN_DEFS ||= chart_contents.deep_symbolize_keys!

  TIMESTAMP_DELTA ||= 2 * (1.second / 1e6)

  BOOKS ||= STERN_DEFS[:books].with_indifferent_access.freeze
  BOOKS_CODES ||= BOOKS.invert.freeze

  ENTRY_PAIRS ||= STERN_DEFS[:entry_pairs].map { |k, v| ["add_#{k}".to_sym, v[:code]] }.to_h.merge(
    STERN_DEFS[:entry_pairs].map { |k, v| ["remove_#{k}".to_sym, -v[:code]] }.to_h
  ).with_indifferent_access.freeze

  ENTRY_PAIRS_CODES ||= ENTRY_PAIRS.invert.freeze
end
