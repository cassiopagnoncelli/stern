# frozen_string_literal: true

module Stern
  class Entry < ApplicationRecord
    validates_presence_of :book_id
    validates_presence_of :gid
    validates_presence_of :tx_id
    validates_presence_of :amount
    validates_presence_of :timestamp
    validates_uniqueness_of :tx_id, scope: [:book_id, :gid]
    validates_uniqueness_of :timestamp, scope: [:book_id, :gid]

    belongs_to :tx, class_name: 'Stern::Tx', optional: true
    belongs_to :book, class_name: 'Stern::Book', optional: true

    before_save do
      eb = self.class.last_entry(book_id, gid, timestamp).last&.ending_balance || 0
      self.amount = amount
      self.ending_balance = eb + amount
      self.timestamp ||= DateTime.current
    end

    before_update do
      raise StandardError, "Ledger is append-only" unless Rails.env.test?
    end

    scope :last_entry, ->(book_id, gid, timestamp) do
      where(book_id: book_id, gid: gid)
        .where('timestamp <= ?', timestamp)
        .order(:timestamp, :id)
        .last(1)
    end

    scope :next_entries, ->(book_id, gid, id, timestamp) do
      where(book_id: book_id, gid: gid)
        .where.not(id: id)
        .where('timestamp > ?', timestamp)
        .order(:timestamp)
    end

    def show
      "%d %s %.2f %.2f" % [gid, book_name, amount.to_f/100, ending_balance.to_f/100]
    end

    def book_name
      BOOKS.invert[book_id]
    end

    def previous_entry
      self.class.where(book_id:, gid:)
        .where('timestamp < ?', timestamp)
        .order(timestamp: :desc)
        .limit(1)
        .first
    end

    def cascade_gid_balance
      previous_balance = previous_entry&.ending_balance || 0
      current_balance = previous_balance + amount
      update!(ending_balance: current_balance) unless current_balance == ending_balance

      running_balance = current_balance
      self.class.next_entries(book_id, gid, id, timestamp).each do |e|
        running_balance += e.amount
        e.update!(ending_balance: running_balance)
      end
      true
    end
  end
end
