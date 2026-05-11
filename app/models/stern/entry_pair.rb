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
    validates :currency, presence: true
    validates :uid, presence: true
    validates :amount, presence: true, numericality: {
      only_integer: true,
      greater_than_or_equal_to: -9_223_372_036_854_775_808,
      less_than_or_equal_to: 9_223_372_036_854_775_807
    }
    before_destroy do
      entries.each(&:destroy!)
    end

    # Chart-derived singletons: for every entry pair declared in
    # `config/charts/<STERN_CHART>.yaml` (and the implicit same-name pair each
    # book gets — see Stern::Chart#build_entry_pairs), this loop defines a
    # class method
    # `add_<pair_name>(uid, sub_gid, add_gid, amount, currency, timestamp:, operation_id:)`
    # that delegates to .double_entry_add with the pair's book_add/book_sub.
    #
    # `sub_gid` is the gid the `book_sub` entry lands at; `add_gid` is the gid
    # the `book_add` entry lands at. Both are required — there is no implicit
    # "both legs at one gid" mode. When a pair's two books shard by the same
    # entity (the common case), callers pass the same value twice; when they
    # shard by different entities (e.g. `investment_invest`:
    # customer_available@customer_id / customer_investment@investment_id),
    # callers pass the two natural gids. The positional order matches
    # `tuples_for_pair(pair, book_sub_gid, book_add_gid, currency)` so the lock
    # side and the write side stay in lockstep.
    #
    # These methods do not appear under `def add_…` anywhere — grep will miss
    # them. The chart YAML is the source of truth; for runtime introspection,
    # call `Stern::EntryPair.pair_methods` or read `Stern.chart.entry_pair_codes.keys`.
    ::Stern.chart.entry_pairs.each_value do |pair|
      define_singleton_method(:"add_#{pair.name}") do |uid, sub_gid, add_gid, amount, currency, timestamp: nil, operation_id: nil|
        double_entry_add(
          pair.name,
          sub_gid,
          add_gid,
          uid,
          pair.book_add,
          pair.book_sub,
          amount,
          currency,
          timestamp,
          operation_id,
        )
      end
    end

    # Names of the chart-derived `add_<pair_name>` singletons defined above.
    # Stable API for tests, docs, and console introspection.
    def self.pair_methods
      ::Stern.chart.entry_pair_codes.keys.map { |name| :"add_#{name}" }
    end

    def self.double_entry_add(code, sub_gid, add_gid, uid, book_add, book_sub, amount, currency, timestamp, operation_id)
      entry_pair = EntryPair.find_or_create_by!(
        code: codes[code], uid:, amount:, currency:, timestamp:, operation_id:,
      )
      Entry.create!(book_id: Book.code(book_add), gid: add_gid, entry_pair_id: entry_pair.id, amount:,        currency:, timestamp:)
      Entry.create!(book_id: Book.code(book_sub), gid: sub_gid, entry_pair_id: entry_pair.id, amount: -amount, currency:, timestamp:)
      entry_pair.id
    end

    def self.double_entry_remove(code, uid, book_add, book_sub, currency)
      entry_pair = EntryPair.find_by!(code: codes[code], uid:, currency:)
      entry_pair_id = entry_pair.id
      Entry.find_by!(book_id: Book.code(book_add), currency:, entry_pair_id:).destroy!
      Entry.find_by!(book_id: Book.code(book_sub), currency:, entry_pair_id:).destroy!

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
