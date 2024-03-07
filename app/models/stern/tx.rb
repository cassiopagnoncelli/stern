# frozen_string_literal: true

# Stern engine.
module Stern
  class Tx < ApplicationRecord
    enum code: TXS

    has_many :entries, class_name: "Stern::Entry"
    belongs_to :operation, class_name: "Stern::Operation" # , foreign_key: :operation_id

    validates :code, presence: true
    validates :uid, presence: true
    validates :amount, presence: true
    validates :uid, uniqueness: { scope: [:code] }
    validate :no_future_timestamp, on: :create

    before_save do
      raise ArgumentError, "timestamp was set" if timestamp.present? && timestamp > DateTime.current
    end

    before_update do
      raise StandardError, "Ledger is append-only" unless Rails.env.test?
    end

    before_destroy do
      entries.each(&:destroy!)
    end

    STERN_DEFS[:txs].each do |name, defs|
      # rubocop:disable Metrics/ParameterLists, Layout/LineLength
      define_singleton_method :"add_#{name}" do |uid, gid, amount, credit_tx_id = nil, timestamp: nil, operation_id: nil|
        double_entry_add("add_#{name}", gid, uid,
                         defs[:book_add], defs[:book_sub], amount, credit_tx_id, timestamp,
                         operation_id,)
      end
      # rubocop:enable Metrics/ParameterLists, Layout/LineLength

      define_singleton_method :"remove_#{name}" do |uid|
        double_entry_remove(:"add_#{name}", uid, defs[:book_add].to_sym,
                            defs[:book_sub].to_sym,)
      end
    end

    # rubocop:disable Metrics/ParameterLists
    def self.double_entry_add(code, gid, uid, book_add, book_sub, amount, credit_tx_id, timestamp,
                              operation_id)
      tx = Tx.find_or_create_by!(code: codes[code], uid:, amount:, credit_tx_id:, timestamp:,
                                 operation_id:,)
      Entry.create!(book_id: Book.code(book_add), gid:, tx_id: tx.id, amount:, timestamp:)
      Entry.create!(book_id: Book.code(book_sub), gid:, tx_id: tx.id, amount: -amount,
                    timestamp:,)
      tx.id
    end
    # rubocop:enable Metrics/ParameterLists

    def self.double_entry_remove(code, uid, book_add, book_sub)
      tx = Tx.find_by!(code: codes[code], uid:)
      tx_id = tx.id
      Entry.find_by!(book_id: Book.code(book_add), tx_id:).destroy!
      Entry.find_by!(book_id: Book.code(book_sub), tx_id:).destroy!

      tx.destroy
      tx_id
    end

    def self.generate_tx_credit_id
      ApplicationRecord.connection.execute("SELECT nextval('credit_tx_id_seq')").first.values.first
    end

    def update
      raise NotImplementedError, "Tx records cannot be updated by design"
    end

    def update!
      raise NotImplementedError, "Tx reccords cannot be updated by design"
    end

    def update_all
      raise NotImplementedError, "Tx reccords cannot be updated by design"
    end

    private

    def no_future_timestamp
      return unless timestamp.presence && timestamp > DateTime.current

      errors.add(:timestamp, "cannot be in the future")
    end
  end
end
