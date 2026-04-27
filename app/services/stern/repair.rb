# frozen_string_literal: true

module Stern
  # Destructive counterpart to Doctor: mutates or wipes ledger state to fix inconsistencies.
  # Read-only audits live on Doctor. Every method here changes data — call sites should be
  # obvious from the namespace.
  class Repair
    def self.rebuild_book_gid_balance(book_id, gid, currency)
      unless book_id.is_a?(Numeric) && ::Stern.chart.book(book_id)
        raise ArgumentError, "book is not valid"
      end

      raise ArgumentError, "gid is not valid" unless gid.is_a?(Numeric)
      raise ArgumentError, "currency is not valid" unless currency.is_a?(Numeric)

      # Take the same (book, gid, currency) advisory lock every writer takes
      # (BaseOperation#acquire_advisory_locks, create_entry / destroy_entry v03),
      # so a rebuild cannot race against an in-flight operation on the same tuple.
      ApplicationRecord.transaction do
        ApplicationRecord.advisory_lock(book_id:, gid:, currency:)
        ApplicationRecord.connection.execute(
          rebuild_book_gid_balance_sanitized_sql(book_id, gid, currency),
        )
      end
    end

    def self.rebuild_book_gid_balance_sanitized_sql(book_id, gid, currency)
      sql = %{
        UPDATE stern_entries
        SET ending_balance = l.new_ending_balance
        FROM (
          SELECT
            id,
            (SUM(amount) OVER (ORDER BY timestamp)) AS new_ending_balance
          FROM stern_entries
          WHERE book_id = :book_id AND gid = :gid AND currency = :currency
          ORDER BY timestamp
        ) l
        WHERE stern_entries.id = l.id
      }
      ApplicationRecord.sanitize_sql_array([ sql, { book_id:, gid:, currency: } ])
    end

    # Rebuild every `(book, gid, currency)` cascade for the given `(gid, currency)`.
    #
    # Piecewise safety model: each per-book rebuild is an independent
    # transaction guarded by the same `(book, gid, currency)` advisory lock
    # that `BaseOperation#acquire_advisory_locks` and `create_entry`
    # take. Between books, ops can commit cross-book cascades; those
    # cascades are produced correctly by `create_entry` under its own
    # lock, so no matter how operations interleave with this method, each
    # book's final `ending_balance` sequence is a correct running sum of
    # its `amount`s. The rebuild is NOT atomic across books — and does not
    # need to be.
    #
    # Only iterates books with entries for this `(gid, currency)`. The
    # general chart has hundreds of books; iterating every book_code
    # regardless would do ~N pointless lock-acquire+UPDATE cycles per
    # call, starving any contention the caller actually cares about.
    # A book that appears AFTER this pluck — because a concurrent op
    # inserts into a previously empty book — does not need a rebuild;
    # the op's own cascade was produced under the advisory lock by
    # `create_entry` and is already consistent.
    def self.rebuild_gid_balance(gid, currency)
      Entry.where(gid:, currency:).distinct.pluck(:book_id).each do |book_id|
        rebuild_book_gid_balance(book_id, gid, currency)
      end
    end

    # Rebuild every cascade in the ledger. Piecewise: inherits the safety
    # model described on `rebuild_gid_balance`. Iterates `(gid, currency)`
    # pairs that currently have entries; pairs that appear between the
    # initial pluck and the end of iteration don't need rebuilding (their
    # cascades were produced correctly under lock).
    def self.rebuild_balances(confirm: false)
      raise ArgumentError, "You must confirm the operation" unless confirm

      Entry.distinct.pluck(:gid, :currency).each do |gid, currency|
        rebuild_gid_balance(gid, currency)
      end
    end

    def self.clear
      if Rails.env.production?
        raise StandardError, "cannot perform in production for security reasons"
      end

      Entry.delete_all
      EntryPair.delete_all
      Operation.delete_all
      ScheduledOperation.delete_all
    end

    def self.requeue
      ScheduledOperation.requeue
    end
  end
end
