# frozen_string_literal: true

require_relative '../../../lib/stern/errors'

module Stern
  # Safety methods.
  class Doctor
    def self.amount_consistent?
      Entry.sum(:amount) == 0
    end

    def self.ending_balance_consistent?(book_id:, gid:)
      current_ending_balance = 0
      Entry.where(book_id:, gid:).order(:timestamp).each do |e|
        return false unless e.ending_balance == e.amount + current_ending_balance
        current_ending_balance += e.amount
      end

      true
    end

    def self.consistent?
      return false unless amount_consistent?

      true
    end

    def self.rebuild_book_gid_balance(book_id, gid)
      raise InvalidBookError unless book_id.is_a?(Numeric)
      raise GidNotSpecifiedError unless book_id.is_a?(Numeric)

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
      sanitized_sql = ActiveRecord::Base.sanitize_sql_array([sql, {book_id:, gid:}])
      ActiveRecord::Base.connection.execute(sanitized_sql)
    end

    def self.rebuild_gid_balance(gid)
      BOOKS.values.each do |book_id|
        rebuild_book_gid_balance(book_id, gid)
      end
    end

    def self.rebuild_balances(confirm = false)
      unless confirm
        raise OperationNotConfirmedError, "You must confirm the operation"
      end

      Entry.pluck(:gid).uniq.each do |gid|
        rebuild_gid_balance(gid)
      end
    end

    def self.clear
      if Rails.env.production?
        raise StandardError, "for security reasons this operation cannot be performed in production"
      end
  
      Entry.delete_all
      Tx.delete_all
    end
  end
end
