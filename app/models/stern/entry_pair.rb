# frozen_string_literal: true

# Stern engine.
module Stern
  class EntryPair < ApplicationRecord
    enum :code, ENTRY_PAIRS

    has_many :entries, class_name: "Stern::Entry", dependent: :restrict_with_exception
    belongs_to :operation, class_name: "Stern::Operation"

    validates :code, presence: true
    validates :uid, presence: true, uniqueness: { scope: [:code] }
    validates :amount, presence: true
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

    STERN_DEFS[:entry_pairs].each do |name, defs|
      # rubocop:disable Metrics/ParameterLists, Layout/LineLength
      define_singleton_method :"add_#{name}" do |uid, gid, amount, credit_entry_pair_id = nil, timestamp: nil, operation_id: nil|
        double_entry_add("add_#{name}", gid, uid,
                         defs[:book_add], defs[:book_sub], amount, credit_entry_pair_id, timestamp,
                         operation_id,)
      end
      # rubocop:enable Metrics/ParameterLists, Layout/LineLength

      define_singleton_method :"remove_#{name}" do |uid|
        double_entry_remove(:"add_#{name}", uid, defs[:book_add].to_sym,
                            defs[:book_sub].to_sym,)
      end
    end

    # rubocop:disable Metrics/ParameterLists
    def self.double_entry_add(code, gid, uid, book_add, book_sub, amount, credit_entry_pair_id, timestamp,
                              operation_id)
      entry_pair = EntryPair.find_or_create_by!(code: codes[code], uid:, amount:, credit_entry_pair_id:, timestamp:,
                                 operation_id:,)
      Entry.create!(book_id: Book.code(book_add), gid:, entry_pair_id: entry_pair.id, amount:, timestamp:)
      Entry.create!(book_id: Book.code(book_sub), gid:, entry_pair_id: entry_pair.id, amount: -amount,
                    timestamp:,)
      entry_pair.id
    end
    # rubocop:enable Metrics/ParameterLists

    def self.double_entry_remove(code, uid, book_add, book_sub)
      entry_pair = EntryPair.find_by!(code: codes[code], uid:)
      entry_pair_id = entry_pair.id
      Entry.find_by!(book_id: Book.code(book_add), entry_pair_id:).destroy!
      Entry.find_by!(book_id: Book.code(book_sub), entry_pair_id:).destroy!

      entry_pair.destroy
      entry_pair_id
    end

    def self.generate_entry_pair_credit_id
      ApplicationRecord.connection.execute("SELECT nextval('credit_entry_pair_id_seq')").first.values.first
    end

    def update
      raise NotImplementedError, "EntryPair records cannot be updated by design"
    end

    def update!
      raise NotImplementedError, "EntryPair reccords cannot be updated by design"
    end

    def update_all
      raise NotImplementedError, "EntryPair reccords cannot be updated by design"
    end

    def pp
      amount_color = amount > 0 ? :green : (amount < 0 ? :red : :white)
      
      colorize_output([
        ["EntryPair", :white],
        ["#{format("%5s", id)}", :white, :bold],
        ["|", :white],
        [timestamp, :purple, :bold],
        ["|", :white],
        ["Grouping UID", :white],
        ["#{format("%5s", uid)}", :yellow, :bold],
        ["|", :white],
        [format("%s", operation&.name || "N/A"), :white, :bold],
        [format("%10s", amount), amount_color, :bold],
        ["| verb", :white],
        [format("%s", code || "N/A"), :orange, :bold]
      ])
    end

    private

    def no_future_timestamp
      return unless timestamp.presence && timestamp > DateTime.current

      errors.add(:timestamp, "cannot be in the future")
    end
  end
end
