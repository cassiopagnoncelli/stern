require "stern/version"
require "stern/engine"

module Stern
  def self.outstanding_balance(book_id = :merchant_balance, timestamp = DateTime.current)
    OutstandingBalanceQuery.new(book_id:, timestamp:).call
  end

  def self.balance(gid, book_id = :merchant_balance, timestamp = DateTime.current)
    BalanceQuery.new(gid:, book_id:, timestamp:).call
  end

  def self.generate_gid
    ActiveRecord::Base.connection.execute("SELECT nextval('gid_seq')").first.values.first
  end
end
