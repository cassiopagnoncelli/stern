require "stern/version"
require "stern/engine"

module Stern
  def self.outstanding_balance(book_id = :merchant_balance, timestamp = DateTime.current)
    OutstandingBalanceQuery.new(book_id:, timestamp:).call
  end

  def self.balance(gid, book_id = :merchant_balance, timestamp = DateTime.current)
    BalanceQuery.new(gid:, book_id:, timestamp:).call
  end
end
