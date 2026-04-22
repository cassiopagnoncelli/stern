# frozen_string_literal: true

# Structural-integrity invariants the ledger must hold — global assertions about
# the *shape* of the record graph, complementing the numeric invariants (S1–S5)
# in spec/models/stern/balance_invariant_spec.rb.
#
#   S. Every EntryPair has exactly two balanced Entry rows:
#      - ep.entries.count == 2
#      - amounts sum to zero (one +amount, one -amount)
#      - each side lands on the book the chart declares for this pair:
#        the +ep.amount entry on `pair.book_add`, the -ep.amount entry on
#        `pair.book_sub`. Implies different book_ids (when the chart declares
#        different books) — strictly stronger: also catches a pair written
#        to two *wrong* books, which the schema cannot detect.
#      - same gid, same currency across both entries and the pair
#
#   T. Every Operation's audit graph is sound:
#      - has_many :entry_pairs is non-empty (a committed Operation without any
#        EntryPair should be impossible under BaseOperation#call's transaction)
#      - every EntryPair has a non-null operation FK
#      - per-op-class params↔gid coherence (ChargePix: params["merchant_id"] ==
#        gid on every written Entry; extend the switch as ops come online)
#
# Guaranteed structurally by EntryPair.double_entry_add and BaseOperation#call —
# these helpers verify those guarantees by walking the committed state, catching
# malformed graphs that would slip past the numeric checks.
module Stern
  module LedgerInvariants
    def assert_entry_pairs_structurally_sound!
      offenders = []

      ::Stern::EntryPair.find_each do |ep|
        entries = ep.entries.order(:id).to_a

        unless entries.size == 2
          offenders << { entry_pair_id: ep.id, problem: "expected 2 entries, found #{entries.size}" }
          next
        end

        a, b = entries
        amounts_cancel = a.amount + b.amount == 0
        unless amounts_cancel
          offenders << {
            entry_pair_id: ep.id,
            problem: "amounts do not cancel (#{a.amount} + #{b.amount} != 0)"
          }
        end
        if a.gid != b.gid
          offenders << { entry_pair_id: ep.id, problem: "entries on different gids (#{a.gid} vs #{b.gid})" }
        end
        if a.currency != b.currency
          offenders << {
            entry_pair_id: ep.id,
            problem: "entries on different currencies (#{a.currency} vs #{b.currency})"
          }
        end
        if ep.currency != a.currency
          offenders << {
            entry_pair_id: ep.id,
            problem: "pair.currency=#{ep.currency} disagrees with entries' currency=#{a.currency}"
          }
        end

        # Each side must land on the book the chart declares for this pair.
        # Identify sides by matching amount sign to ep.amount — only meaningful
        # when amounts cancel (otherwise the two-entry shape is already broken
        # and the side assignment is ambiguous).
        next unless amounts_cancel

        pair_def = ::Stern.chart.entry_pair(ep.code.to_sym)
        next unless pair_def

        expected_add = ::Stern.chart.book_code(pair_def.book_add)
        expected_sub = ::Stern.chart.book_code(pair_def.book_sub)
        add_side, sub_side = a.amount == ep.amount ? [ a, b ] : [ b, a ]

        if add_side.book_id != expected_add
          offenders << {
            entry_pair_id: ep.id,
            problem: "book_add side on book_id=#{add_side.book_id}, expected #{expected_add} (:#{pair_def.book_add})"
          }
        end
        if sub_side.book_id != expected_sub
          offenders << {
            entry_pair_id: ep.id,
            problem: "book_sub side on book_id=#{sub_side.book_id}, expected #{expected_sub} (:#{pair_def.book_sub})"
          }
        end
      end

      expect(offenders).to eq([]),
        "EntryPair structural invariant violated (first 5): #{offenders.first(5).inspect}"
    end

    def assert_operations_integral!
      offenders = []

      ::Stern::Operation.find_each do |op|
        pairs = op.entry_pairs.to_a
        if pairs.empty?
          offenders << { operation_id: op.id, name: op.name, problem: "no associated EntryPairs" }
          next
        end

        # Per-op-class params↔ledger coherence. The only real op today is
        # ChargePix; future op classes should add their own branch rather than
        # a generic rule (different ops relate gid to params differently).
        case op.name
        when "ChargePix"
          expected_gid = op.params["merchant_id"].to_i
          bad_gids = pairs.flat_map { |ep| ep.entries.pluck(:gid) }.uniq.reject { |g| g == expected_gid }
          unless bad_gids.empty?
            offenders << {
              operation_id: op.id,
              name: op.name,
              problem: "entries have gid(s) #{bad_gids.inspect} != params.merchant_id=#{expected_gid}"
            }
          end
        end
      end

      # Defense-in-depth: EntryPair.operation_id is NOT NULL at the DB level and
      # `belongs_to :operation` is required in Ruby, but we still sweep — a
      # malformed migration or raw SQL insert is the exact class of bug these
      # structural invariants are meant to catch.
      ::Stern::EntryPair.where(operation_id: nil).find_each do |ep|
        offenders << { entry_pair_id: ep.id, problem: "EntryPair.operation_id is NULL" }
      end

      expect(offenders).to eq([]),
        "Operation integrity invariant violated (first 5): #{offenders.first(5).inspect}"
    end
  end
end

RSpec.configure do |config|
  config.include Stern::LedgerInvariants
end
