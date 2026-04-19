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
    if name_or_index.is_a?(String)
      STERN_CURRENCIES[name.to_s.strip.upcase.presence]
    elsif name_or_index.is_a?(Integer)
      STERN_CURRENCIES_R[idx]
    else
      raise UnknownCurrencyError
    end
  end
end
