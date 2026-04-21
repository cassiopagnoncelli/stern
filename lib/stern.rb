require "xxhash"
require "stern/version"
require "stern/engine"

module Kernel
  def chart_hash(str)
    raise Stern::ArgumentMustBeString unless str.is_a?(String) || str.is_a?(Symbol)

    XXhash.xxh64(str.to_s) & Stern::INT_MASK
  end
end

module Stern
  INT_MASK = ((1 << 31) - 1).freeze

  def self.generate_gid
    ApplicationRecord.generate_gid
  end

  def self.chart_hash(str)
    raise ArgumentMustBeString unless str.is_a?(String) || str.is_a?(Symbol)

    XXhash.xxh64(str.to_s) & INT_MASK
  end

  def self.outstanding_balance(book_id = :merchant_balance, timestamp = DateTime.current)
    OutstandingBalanceQuery.new(book_id:, timestamp:).call
  end

  def self.balance(gid, book_id = :merchant_balance, timestamp = DateTime.current)
    BalanceQuery.new(gid:, book_id:, timestamp:).call
  end

  def self.cur(name_or_index, result: :both)
    raise UnknownCurrencyError if name_or_index.blank?
    raise UnrecognizedArgument unless [:both, :index, :string].include?(result)

    if name_or_index.is_a?(String)
      name = name_or_index.strip.upcase
      raise UnknownCurrencyError unless STERN_CURRENCIES.keys.include?(name)
      raise ArgumentMustBeInteger if result == :string

      STERN_CURRENCIES[name]
    elsif name_or_index.is_a?(Integer)
      raise UnknownCurrencyError unless STERN_CURRENCIES_R.keys.include?(name_or_index)
      raise ArgumentMustBeString if result == :integer

      STERN_CURRENCIES_R[name_or_index]
    else
      raise UnknownCurrencyError
    end
  end
end
