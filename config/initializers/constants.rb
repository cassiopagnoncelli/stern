# frozen_string_literal: true

# By default, ending balance should be filled for every new transaction.
# For optimal bulk insertion, disabling it will speed up importing; combine with Doctor.rebuild_balances
STERN_AUTOFILL_ENDING_BALANCE = ![false, 'false'].include?(ENV.fetch('STERN_AUTOFILL_ENDING_BALANCE', true))

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
STERN_TIMESTAMP_DELTA = 1.second / 1e6
