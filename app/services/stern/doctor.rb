# frozen_string_literal: true

module Stern
  # Safety methods.
  class Doctor
    def self.consistent?
      return false unless amount_consistent?

      true
    end

    def self.amount_consistent?
      Entry.sum(:amount).zero?
    end

    def self.ending_balance_consistent?(book_id:, gid:)
      current_ending_balance = 0
      Entry.where(book_id:, gid:).order(:timestamp).each do |e|
        return false unless e.ending_balance == e.amount + current_ending_balance

        current_ending_balance += e.amount
      end

      true
    end

    def self.ending_balances_inconsistencies_across_books(gid:)
      entry_ids = []
      BOOKS.each_value do |book_id|
        entry_ids += ending_balances_inconsistencies(book_id:, gid:)
      end
      entry_ids
    end

    def self.ending_balances_inconsistencies(book_id:, gid:) # rubocop:disable Metrics/MethodLength
      sql = %{
        SELECT entry_id
        FROM (
          SELECT
            se.id AS entry_id,
            CASE WHEN ending_balance = checked_ending_balance THEN 0 ELSE 1 END AS inconsistent
          FROM (
            SELECT id, ending_balance
            FROM stern_entries
            WHERE book_id = :book_id AND gid = :gid
          ) se
          LEFT JOIN (
            SELECT
              id,
              (SUM(amount) OVER (ORDER BY timestamp)) AS checked_ending_balance
            FROM stern_entries
            WHERE book_id = :book_id AND gid = :gid
            ORDER BY timestamp
          ) se2 ON se.id = se2.id
        ) inconsistencies_results
        WHERE inconsistent = 1
      }
      sanitized_sql = ApplicationRecord.sanitize_sql_array([sql, { book_id:, gid: }])
      results = ApplicationRecord.connection.execute(sanitized_sql)
      results.to_a.flatten
    end

    def self.rebuild_book_gid_balance(book_id, gid)
      unless book_id.is_a?(Numeric) && book_id.in?(BOOKS.values)
        raise ArgumentError,
              "book is not valid"
      end
      raise ArgumentError, "gid is not valid" unless gid.is_a?(Numeric)

      ApplicationRecord.connection.execute(
        rebuild_book_gid_balance_sanitized_sql(
          book_id,
          gid,
        ),
      )
    end

    def self.rebuild_book_gid_balance_sanitized_sql(book_id, gid)
      sql = %{
        UPDATE stern_entries
        SET ending_balance = l.new_ending_balance
        FROM (
          SELECT
            id,
            (SUM(amount) OVER (ORDER BY timestamp)) AS new_ending_balance
          FROM stern_entries
          WHERE book_id = :book_id AND gid = :gid
          ORDER BY timestamp
        ) l
        WHERE stern_entries.id = l.id
      }
      ApplicationRecord.sanitize_sql_array([sql, { book_id:, gid: }])
    end

    def self.rebuild_gid_balance(gid)
      BOOKS.each_value do |book_id|
        rebuild_book_gid_balance(book_id, gid)
      end
    end

    def self.rebuild_balances(confirm: false)
      raise ArgumentError, "You must confirm the operation" unless confirm

      Entry.distinct.pluck(:gid).each do |gid|
        rebuild_gid_balance(gid)
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

    # Queue.
    def self.requeue
      ScheduledOperation.requeue
    end
  end
end
