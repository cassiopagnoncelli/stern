require "stern/version"
require "stern/errors"
require "stern/ansi_print"
require "stern/engine"
require "stern/chart"
require "stern/currencies"
require "stern/metrics"
require "stern/workers"

module Stern
  class << self
    attr_accessor :chart, :currencies
    attr_writer :in_progress_timeout_seconds
  end

  # How long a scheduled operation may sit in `:in_progress` before
  # `ScheduledOperationService.clear_in_progress` considers the consumer dead
  # and recycles it. Resolution order:
  #   1. Explicit assignment (`Stern.in_progress_timeout_seconds = 1800`)
  #   2. `STERN_IN_PROGRESS_TIMEOUT_SECONDS` env var
  #   3. Default 600s
  # Host apps with legitimately slow ops (external API calls, large repairs)
  # should bump this past their longest expected op runtime.
  def self.in_progress_timeout_seconds
    @in_progress_timeout_seconds || ENV.fetch("STERN_IN_PROGRESS_TIMEOUT_SECONDS", 600).to_i
  end

  def self.outstanding_balance(book_id, currency, timestamp = Time.current)
    OutstandingBalanceQuery.new(book_id:, currency:, timestamp:).call
  end

  def self.balance(gid, book_id, currency, timestamp = Time.current)
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
