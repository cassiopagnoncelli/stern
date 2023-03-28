# frozen_string_literal: true

module Stern
  # Entry is the atomic piece of bookkeeping.
  #
  # For Double-Entry Bookkeeping, each financial transaction is recorded in at least two
  # different nominal ledger accounts within the financial accounting system, so that the
  # total debits equals the total credits in the general ledger.
  #
  class Entry < ApplicationRecord
    validates_presence_of :book_id
    validates_presence_of :gid
    validates_presence_of :tx_id
    validates_presence_of :amount
    validates_presence_of :timestamp
    validates_uniqueness_of :tx_id, scope: [:book_id, :gid]
    validates_uniqueness_of :timestamp, scope: [:book_id, :gid]

    belongs_to :tx, class_name: 'Stern::Tx', optional: true

    before_save do
      eb = self.class.last_entry(book_id, gid, timestamp).last&.ending_balance || 0
      self.amount = amount
      self.ending_balance = eb + amount
      self.timestamp ||= DateTime.current
    end

    scope :last_entry, ->(book_id, gid, timestamp) do
      where(book_id: book_id, gid: gid)
        .where('timestamp < ?', timestamp)
        .order(:timestamp, :id)
        .last(1)
    end

    scope :next_entries, ->(book_id, gid, id, timestamp) do
      where(book_id: book_id, gid: gid)
        .where.not(id: id)
        .where('timestamp > ?', timestamp)
        .order(:timestamp)
    end

    # Because this query is computationally expensive we may write a PL/pgSQL procedure
    # to cascade balance updates given reference entry id, book_id, gid.
    #
    # Note. Bare in mind such a query should be computationally cheap, deadlock free,
    # and easy to port to a another database engine.
    def cascade_gid_balance
      s = ending_balance
      self.class.next_entries(book_id, gid, id, timestamp).each do |e|
        s += e.amount
        e.update!(ending_balance: s)
      end
      true
    end
  end
end
