# frozen_string_literal: true

# Chart of accounts configuration.
STERN_DEFS = YAML.load_file("#{Rails.root}/config/chart_of_accounts.yml").deep_symbolize_keys!

# Maps transactions name to codes.
STERN_TX_CODES = STERN_DEFS[:txs].map do |k, v|
  [["add_#{k}".to_sym, v[:code]], ["remove_#{k}".to_sym, v[:code] + 2]]
end.flatten(1).to_h

# Maps transactions names to double-entries A and B
STERN_TX_2TREES = STERN_DEFS[:txs].map { |_k, g|
  [g[:code], [STERN_DEFS[:books][g[:book1].to_sym], STERN_DEFS[:books][g[:book2].to_sym]]]
}.to_h

# Minimum timestamp difference.
STERN_TIMESTAMP_DELTA = 2 * (1.second / 1e6)
