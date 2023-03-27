# frozen_string_literal: true

module Stern
  # Safety methods.
  class Doctor < ApplicationRecord
    OperationNotConfirmed = class.new(StandardError)

    def self.doctor_consistency
      Entry.sum(:amount) == 0
    end

    def self.rebuild_gid_balance(gid)
      Tx.books.values.each do |book_id|
        Stern::Base.connection.execute(%{
          UPDATE stern_entries
          SET ending_balance = l.new_ending_balance
          FROM (
            SELECT
              id,
              (SUM(amount) OVER (ORDER BY timestamp)) AS new_ending_balance
            FROM stern_entries
            WHERE book_id = #{book_id} AND gid = #{gid}
            ORDER BY timestamp
          ) l
          WHERE stern_entries.id = l.id
        })
      end
    end

    def self.rebuild_balances(confirm = false)
      raise(OperationNotConfirmed, "You must confirm the operation") unless confirm

      Stern::Entry.pluck(:gid).uniq.each do |gid|
        rebuild_gid_balance(gid)
      end
    end
  end
end
