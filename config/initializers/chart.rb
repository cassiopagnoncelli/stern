# frozen_string_literal: true

module Stern
  # Loading chart.
  available_charts = Dir[Engine.root.join("config/charts/*")].map { |file| file.split("/").last.split(".").first }
  chart_name = ENV.fetch("STERN_CHART", "general")
  unless chart_name.in?(available_charts)
    raise "STERN_CHART=\"#{chart_name}\" should be either of #{available_charts}"
  end
  chart_path ||= Engine.root.join("config/charts/#{chart_name}.yaml").to_s.freeze
  chart_contents ||= YAML.load_file(chart_path)

  # Parse chart.
  STERN_DEFS ||= chart_contents.deep_symbolize_keys!.freeze

  TIMESTAMP_DELTA ||= 2 * (1.second / 1e6).freeze

  # Define books.
  BOOKS ||= STERN_DEFS[:books].map { |name| [name, chart_hash(name)] }.to_h.with_indifferent_access.freeze
  BOOKS_CODES ||= BOOKS.invert.freeze

  # Define entry pairs.
  ENTRY_PAIRS ||= BOOKS.map { |name, code| ["add_#{name}".to_sym, code] }.to_h.
    merge(
      BOOKS.map { |name, code| ["sub_#{name}".to_sym, -code] }.to_h
    ).merge(
      STERN_DEFS[:entry_pairs].map { |name, _h| ["add_#{name}".to_sym, chart_hash(name)] }.to_h
    ).merge(
      STERN_DEFS[:entry_pairs].map { |name, _h| ["remove_#{name}".to_sym, -chart_hash(name)] }.to_h
    ).with_indifferent_access.freeze

  ENTRY_PAIRS_CODES ||= ENTRY_PAIRS.invert.freeze

  # Check validity.
  books_codes = STERN_DEFS[:books].map { |name| chart_hash(name) }
  entry_pairs_codes = STERN_DEFS[:entry_pairs].keys.map { |name| chart_hash(name) }

  if books_codes.count != books_codes.uniq.count
    raise BooksHashCollision, "collision with implicit book names"
  elsif books_codes.intersect?(entry_pairs_codes)
    raise BooksHashCollision, "collision between implicit book names and entry pairs book names"
  elsif ENTRY_PAIRS_CODES.keys.count != ENTRY_PAIRS_CODES.keys.uniq.count
    raise EntryPairHashCollision, "collision in entry pairs codes"
  end
end
