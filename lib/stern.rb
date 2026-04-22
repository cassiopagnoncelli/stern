require "stern/version"
require "stern/errors"
require "stern/ansi_print"
require "stern/engine"
require "stern/chart"
require "stern/currencies"

module Stern
  class << self
    attr_accessor :chart, :currencies
  end

  def self.generate_gid
    ApplicationRecord.generate_gid
  end

  def self.outstanding_balance(book_id, currency, timestamp = DateTime.current)
    OutstandingBalanceQuery.new(book_id:, currency:, timestamp:).call
  end

  def self.balance(gid, book_id, currency, timestamp = DateTime.current)
    BalanceQuery.new(gid:, book_id:, currency:, timestamp:).call
  end

  # Look up a currency by name or index. `result:` controls the return type:
  #   - `:index` always returns the Integer code
  #   - `:string` always returns the canonical uppercase name
  #   - `:both`  (default) returns the "other" representation — the Integer if
  #     given a name, the name if given an Integer. Symmetric with the identity
  #     that `cur(cur(x, result: :both), result: :both) == x`.
  def self.cur(name_or_index, result: :both)
    raise UnknownCurrencyError if name_or_index.blank?
    raise UnrecognizedArgument unless [ :both, :index, :string ].include?(result)

    name, code =
      case name_or_index
      when String  then [ name_or_index.strip.upcase, nil ]
      when Integer then [ nil, name_or_index ]
      else raise UnknownCurrencyError
      end

    code ||= currencies.code(name)
    name ||= currencies.name(code)
    raise UnknownCurrencyError unless code && name

    case result
    when :index  then code
    when :string then name
    when :both   then name_or_index.is_a?(String) ? code : name
    end
  end
end
