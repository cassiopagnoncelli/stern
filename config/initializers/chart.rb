# frozen_string_literal: true

module Stern
  # Load chart from file.
  available_charts = Dir[Engine.root.join("config/charts/*")].map { |file| file.split("/").last.split(".").first }
  chart_name = ENV.fetch("STERN_CHART", "general")
  unless chart_name.in?(available_charts)
    raise "STERN_CHART=\"#{chart_name}\" should be either of #{available_charts}"
  end
  chart_path ||= Engine.root.join("config/charts/#{chart_name}.yaml").to_s.freeze
  chart_contents ||= YAML.load_file(chart_path)

  STERN_DEFS ||= chart_contents.deep_symbolize_keys!.freeze

  # Minimum time difference between entries, since timestamp must be unique.
  # NOTE: This needs proper refactoring, particularly when multiple machines are involved.
  TIMESTAMP_DELTA ||= 2 * (1.second / 1e6).freeze

  # 
  # Books and Entry Pairs.
  #
  BOOKS ||= STERN_DEFS[:books] + STERN_DEFS[:books].map { |name| "#{name}_0" }
  BOOKS_CODES ||= STERN_DEFS[:books].map { |name| [name, chart_hash(name)] }.to_h.with_indifferent_access.freeze
  BOOKS_INDEX ||= BOOKS_CODES.invert.freeze

  ENTRY_PAIRS_BOOKS_CODES ||= STERN_DEFS[:books].map { |name| [name, chart_hash(name)] }.to_h.with_indifferent_access.freeze

  ENTRY_PAIRS ||= (STERN_DEFS[:books] + STERN_DEFS[:entry_pairs].keys).map(&:to_sym).freeze
  ENTRY_PAIRS_CODES ||= ENTRY_PAIRS.map { |name| [name, chart_hash(name)] }.to_h.with_indifferent_access.freeze
  ENTRY_PAIRS_INDEX ||= ENTRY_PAIRS_CODES.invert.freeze
  ENTRY_PAIRS_ADD ||= STERN_DEFS[:entry_pairs].transform_values { _1.fetch(:book_add) }.freeze
  ENTRY_PAIRS_SUB ||= STERN_DEFS[:entry_pairs].transform_values { _1.fetch(:book_sub) }.freeze
  ENTRY_PAIRS_ADD_CODES ||= STERN_DEFS[:entry_pairs].transform_values { BOOKS_CODES[_1.fetch(:book_add)] }.freeze
  ENTRY_PAIRS_SUB_CODES ||= STERN_DEFS[:entry_pairs].transform_values { BOOKS_CODES[_1.fetch(:book_sub)] }.freeze

  if BOOKS_INDEX.keys.count != BOOKS_INDEX.keys.uniq.count
    raise BooksHashCollision, "collision with implicit book names"
  elsif ENTRY_PAIRS_CODES.keys.count != ENTRY_PAIRS_CODES.keys.uniq.count
    raise EntryPairHashCollision, "collision in entry pairs names"
  elsif ENTRY_PAIRS_INDEX.keys.count != ENTRY_PAIRS_INDEX.keys.uniq.count
    raise BooksHashCollision, "collision between implicit book names and entry pairs book names"
  end
end
