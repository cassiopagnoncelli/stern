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

      ApplicationRecord.connection.execute(
        rebuild_book_gid_balance_sanitized_sql(book_id, gid, currency),
      )
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

    def self.rebuild_gid_balance(gid, currency)
      ::Stern.chart.book_codes.each do |book_id|
        rebuild_book_gid_balance(book_id, gid, currency)
      end
    end

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
