# frozen_string_literal: true

# Structural-integrity invariants the ledger must hold — global assertions about
# the *shape* of the record graph, complementing the numeric invariants (S1–S5)
# in spec/models/stern/balance_invariant_spec.rb.
#
#   S. Every EntryPair has exactly two balanced Entry rows:
#      - ep.entries.count == 2
#      - amounts sum to zero (one +amount, one -amount)
#      - two distinct book_ids (book_add vs book_sub)
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
        if a.amount + b.amount != 0
          offenders << {
            entry_pair_id: ep.id,
            problem: "amounts do not cancel (#{a.amount} + #{b.amount} != 0)"
          }
        end
        if a.book_id == b.book_id
          offenders << { entry_pair_id: ep.id, problem: "both entries on same book_id=#{a.book_id}" }
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
