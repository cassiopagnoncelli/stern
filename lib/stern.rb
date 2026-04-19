require "stern/version"
require "stern/engine"

module Stern
  def self.generate_gid
    ApplicationRecord.generate_gid
  end

  def self.outstanding_balance(book_id = :merchant_balance, timestamp = DateTime.current)
    OutstandingBalanceQuery.new(book_id:, timestamp:).call
  end

  def self.balance(gid, book_id = :merchant_balance, timestamp = DateTime.current)
    BalanceQuery.new(gid:, book_id:, timestamp:).call
  end

  def self.curidx(name)
    STERN_CURRENCIES[name.to_s]
  end

  def self.cur(idx)
    STERN_CURRENCIES_R[idx]
  end
end
