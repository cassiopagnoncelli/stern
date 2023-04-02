# frozen_string_literal: true

# Stern engine.
module Stern
  class Tx < ApplicationRecord
    enum code: TXS

    has_many :entries, class_name: 'Stern::Entry'

    validates_presence_of :code
    validates_presence_of :uid
    validates_presence_of :amount
    validates_presence_of :timestamp
    validates_uniqueness_of :uid, scope: [:code]
    validate :no_future_timestamp, on: :create

    before_update do
      raise StandardError, "Ledger is append-only" unless Rails.env.test?
    end

    STERN_DEFS[:txs].each do |name, defs|
      define_singleton_method "add_#{name}".to_sym do |uid, gid, amount, credit_tx_id = nil, timestamp: DateTime.current, cascade: false|
        double_entry_add("add_#{name}", gid, uid,
                          defs[:book_add], defs[:book_sub], amount, credit_tx_id, timestamp, cascade)
      end

      define_singleton_method "remove_#{name}".to_sym do |uid|
        double_entry_remove("add_#{name}".to_sym, uid, defs[:book_add].to_sym, defs[:book_sub].to_sym)
      end
    end

    # Double-entry operations.
    # 
    # Note: when timestamp is not the immediate current time therefore implying this transaction
    # will not be the latest by timestamp, the ending balances for all transactions after this
    # timestamp will be incorrect. Hence, *always* set cascade = true in these operations.
    def self.double_entry_add(code, gid, uid, book_add, book_sub, amount, credit_tx_id, timestamp, cascade)
      tx = Tx.find_or_create_by!(code: codes[code], uid:, amount:, credit_tx_id:, timestamp:)
      e1 = Entry.create!(book_id: Book.code(book_add), gid:, tx_id: tx.id, amount:, timestamp:)
      e2 = Entry.create!(book_id: Book.code(book_sub), gid:, tx_id: tx.id, amount: -amount, timestamp:)
      [e1.cascade_gid_balance, e2.cascade_gid_balance] if cascade
      tx.id
    end

    def self.double_entry_remove(code, uid, book_add, book_sub)
      tx = Tx.find_by!(code: codes[code], uid:)
      tx_id = tx.id
      e1 = Entry.find_by!(book_id: Book.code(book_add), tx_id:)
      e2 = Entry.find_by!(book_id: Book.code(book_sub), tx_id:)

      e1.update(amount: 0, ending_balance: e1.ending_balance - e1.amount)
      e2.update(amount: 0, ending_balance: e2.ending_balance - e2.amount)

      e1.cascade_gid_balance
      e2.cascade_gid_balance

      e1.destroy
      e2.destroy

      tx.destroy
      tx_id
    end

    def self.generate_tx_credit_id
      self.connection.execute("SELECT nextval('credit_tx_id_seq')").first.values.first
    end

    def cascade_gid_balance
      entries.each(&:cascade_gid_balance)
      entries.reload
    end

    private

    def no_future_timestamp
      errors.add(:timestamp, 'cannot be in the future') if timestamp > DateTime.current
    end
  end
end
