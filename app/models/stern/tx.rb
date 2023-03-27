# frozen_string_literal: true

# Stern engine.
module Stern
  raise InvalidTxName if STERN_TX_CODES.keys.detect { |e| STERN_TX_CODES.keys.count(e) > 1 }
  raise InvalidTxCode if STERN_TX_CODES.values.detect { |e| STERN_TX_CODES.values.count(e) > 1 }
  raise InconsistentDefinitions unless STERN_TX_2TREES.flatten(2).select(&:nil?).blank?

  # In a Double-Entry bookkeeping, a financial transaction combines two entries, one for
  # credit, one for debit, in such a way credits = debits.
  #
  # Notes.
  # 1. Furthermore we register each transaction by its name for auditing purposes.
  # 2. Transactions are append-only whereas entries are not.
  #
  class Tx < ApplicationRecord
    enum book: STERN_DEFS[:books]
    enum code: STERN_TX_CODES

    has_many :entries, class_name: 'Stern::Entry'

    validates_presence_of :code
    validates_presence_of :uid
    validates_presence_of :amount
    validates_presence_of :timestamp
    validate :no_future_timestamp, on: :create

    class << self
      # Note. Edit transactions do not exist for entries would otherwise have multiple
      # transactions this way increasing audit complexity. A preferred way is to simply
      # redo the transaction all along.
      STERN_DEFS[:txs].each do |name, defs|
        define_method "add_#{name}".to_sym do |uid, gid, amount, timestamp = Time.current, credit_tx_id = nil, cascade: false|
          double_entry_add("add_#{name}".to_sym, gid, uid,
                            defs[:book1].to_sym, defs[:book2].to_sym,
                            defs[:positive] ? amount : -amount, timestamp, credit_tx_id, cascade)
        end

        define_method "remove_#{name}".to_sym do |uid|
          double_entry_remove("add_#{name}".to_sym, uid, defs[:book1].to_sym, defs[:book2].to_sym)
        end
      end
    end

    #
    # Double-entry operations.
    #
    def self.double_entry_add(code, gid, uid, book1, book2, amount, timestamp, credit_tx_id, cascade)
      tx = Tx.find_or_create_by!(code: codes[code], uid: uid, amount: amount, timestamp: timestamp, credit_tx_id: credit_tx_id)
      e1 = Entry.create!(book_id: books[book1], gid: gid, tx_id: tx.id, amount: amount, timestamp: timestamp)
      e2 = Entry.create!(book_id: books[book2], gid: gid, tx_id: tx.id, amount: -amount, timestamp: timestamp)
      [e1.cascade_gid_balance, e2.cascade_gid_balance] if cascade
      tx.id
    end

    def self.double_entry_remove(code, uid, book1, book2)
      tx = Tx.find_by!(code: codes[code], uid: uid)
      tx_id = tx.id
      e1 = Entry.find_by!(book_id: books[book1], tx_id: tx_id)
      e2 = Entry.find_by!(book_id: books[book2], tx_id: tx_id)

      e1.update(amount: 0, ending_balance: e1.ending_balance - e1.amount)
      e2.update(amount: 0, ending_balance: e2.ending_balance - e2.amount)

      e1.cascade_gid_balance
      e2.cascade_gid_balance

      e1.destroy
      e2.destroy

      tx.destroy
      tx_id
    end

    private

    def no_future_timestamp
      errors.add(:timestamp, 'cannot be in the future') if timestamp > Time.current
    end
  end
end
