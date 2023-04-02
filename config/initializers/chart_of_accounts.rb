# frozen_string_literal: true

STERN_DEFS = YAML.load_file("#{Rails.root}/config/chart_of_accounts.yml").deep_symbolize_keys!

module Stern
  TIMESTAMP_DELTA = 2 * (1.second / 1e6)

  BOOKS = STERN_DEFS[:books].with_indifferent_access.freeze

  TXS = STERN_DEFS[:txs].map { |k, v| ["add_#{k}".to_sym, v[:code]] }.to_h.merge(
    STERN_DEFS[:txs].map { |k, v| ["remove_#{k}".to_sym, -v[:code]] }.to_h
  ).with_indifferent_access.freeze
  
  TX_ENTRIES = STERN_DEFS[:txs].with_indifferent_access.freeze

  TX_ENTRIES_CODES = STERN_DEFS[:txs].map { |_k, g|
    [g[:code],
    [
      STERN_DEFS[:books][g[:book_add].to_sym],
      STERN_DEFS[:books][g[:book_sub].to_sym]]
    ]
  }.to_h.with_indifferent_access.freeze
end
