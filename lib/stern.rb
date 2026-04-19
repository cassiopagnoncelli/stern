require "stern/version"
require "stern/engine"

module Stern
  UnknownCurrencyError = Class.new(StandardError)

  def self.generate_gid
    ApplicationRecord.generate_gid
  end

  def self.outstanding_balance(book_id = :merchant_balance, timestamp = DateTime.current)
    OutstandingBalanceQuery.new(book_id:, timestamp:).call
  end

  def self.balance(gid, book_id = :merchant_balance, timestamp = DateTime.current)
    BalanceQuery.new(gid:, book_id:, timestamp:).call
  end

  def self.cur(name_or_index)
    raise UnknownCurrencyError if name_or_index.blank?

    if name_or_index.is_a?(String)
      name = name_or_index.strip.upcase
      return "bleh" unless STERN_CURRENCIES.keys.include?(name)

      STERN_CURRENCIES[name]
    elsif name_or_index.is_a?(Integer)
      return "bleh" unless STERN_CURRENCIES_R.keys.include?(name_or_index)

      STERN_CURRENCIES_R[name_or_index]
    else
      raise UnknownCurrencyError
    end
  end
end
