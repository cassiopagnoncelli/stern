require "stern/version"
require "stern/engine"
require "stern/chart"

module Stern
  class << self
    attr_accessor :chart
  end

  def self.generate_gid
    ApplicationRecord.generate_gid
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
