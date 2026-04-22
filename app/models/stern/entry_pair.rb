# frozen_string_literal: true

# Stern engine.
module Stern
  class EntryPair < ApplicationRecord
    include AppendOnly
    include NoFutureTimestamp

    enum :code, ::Stern.chart.entry_pair_codes

    has_many :entries, class_name: "Stern::Entry", dependent: :restrict_with_exception
    belongs_to :operation, class_name: "Stern::Operation"

    validates :code, presence: true
    validates :uid, presence: true, uniqueness: { scope: [ :code ] }
    validates :amount, presence: true, numericality: {
      only_integer: true,
      greater_than_or_equal_to: -9_223_372_036_854_775_808,
      less_than_or_equal_to: 9_223_372_036_854_775_807
    }
    before_destroy do
      entries.each(&:destroy!)
    end

    ::Stern.chart.entry_pairs.each_value do |pair|
      define_singleton_method(:"add_#{pair.name}") do |uid, gid, amount, timestamp: nil, operation_id: nil|
        double_entry_add(
          pair.name,
          gid,
          uid,
          pair.book_add,
          pair.book_sub,
          amount,
          timestamp,
          operation_id,
        )
      end
    end

    def self.double_entry_add(code, gid, uid, book_add, book_sub, amount, timestamp, operation_id)
      entry_pair = EntryPair.find_or_create_by!(code: codes[code], uid:, amount:, timestamp:, operation_id:)
      Entry.create!(book_id: Book.code(book_add), gid:, entry_pair_id: entry_pair.id, amount:, timestamp:)
      Entry.create!(book_id: Book.code(book_sub), gid:, entry_pair_id: entry_pair.id, amount: -amount, timestamp:)
      entry_pair.id
    end

    def self.double_entry_remove(code, uid, book_add, book_sub)
      entry_pair = EntryPair.find_by!(code: codes[code], uid:)
      entry_pair_id = entry_pair.id
      Entry.find_by!(book_id: Book.code(book_add), entry_pair_id:).destroy!
      Entry.find_by!(book_id: Book.code(book_sub), entry_pair_id:).destroy!

      entry_pair.destroy!
      entry_pair_id
    end

    def pp
      amount_color = amount > 0 ? :green : (amount < 0 ? :red : :white)

      AnsiPrint.puts_colorized([
        [ "EntryPair", :white ],
        [ "#{format("%5s", id)}", :white, :bold ],
        [ "|", :white ],
        [ timestamp, :purple, :bold ],
        [ "|", :white ],
        [ "Grouping UID", :white ],
        [ "#{format("%5s", uid)}", :yellow, :bold ],
        [ "|", :white ],
        [ format("%s", operation&.name || "N/A"), :white, :bold ],
        [ format("%10s", amount), amount_color, :bold ],
        [ "| verb", :white ],
        [ format("%s", code || "N/A"), :orange, :bold ]
      ])
    end
  end
end
