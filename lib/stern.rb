require "stern/version"
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

  def self.outstanding_balance(book_id = :merchant_balance, timestamp = DateTime.current)
    OutstandingBalanceQuery.new(book_id:, timestamp:).call
  end

  def self.balance(gid, book_id = :merchant_balance, timestamp = DateTime.current)
    BalanceQuery.new(gid:, book_id:, timestamp:).call
  end

  def self.cur(name_or_index, result: :both)
    raise UnknownCurrencyError if name_or_index.blank?
    raise UnrecognizedArgument unless [ :both, :index, :string ].include?(result)

    case name_or_index
    when String
      name = name_or_index.strip.upcase
      code = currencies.code(name)
      raise UnknownCurrencyError unless code
      raise ArgumentMustBeInteger if result == :string

      code
    when Integer
      name = currencies.name(name_or_index)
      raise UnknownCurrencyError unless name
      raise ArgumentMustBeString if result == :integer

      name
    else
      raise UnknownCurrencyError
    end
  end
end
