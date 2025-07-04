# frozen_string_literal: true

module Stern
  class Entry < ApplicationRecord
    validates :book_id, presence: true
    validates :gid, presence: true
    validates :entry_pair_id, presence: true
    validates :amount, presence: true, exclusion: { in: [0] }
    validates :entry_pair_id, uniqueness: { scope: [:book_id, :gid] }
    validates :timestamp, uniqueness: { scope: [:book_id, :gid] }

    belongs_to :entry_pair, class_name: "Stern::EntryPair", optional: true
    belongs_to :book, class_name: "Stern::Book", optional: true

    before_update do
      raise NotImplementedError, "Entry records cannot be updated by design"
    end

    before_create do
      if timestamp.presence && timestamp > DateTime.current
        raise(ArgumentError,
              "timestamp cannot be in the future",)
      end
      raise ArgumentError, "amount must be non-zero integer" if amount.blank? || amount.zero?
      raise ArgumentError, "book_id undefined" if book_id.blank?
      raise ArgumentError, "book_id undefined" if book_id.blank?
      raise ArgumentError, "gid undefined" if gid.blank?
      raise ArgumentError, "entry_pair_id undefined" if entry_pair_id.blank?
    end

    scope :last_entry, lambda { |book_id, gid, timestamp|
      where(book_id:, gid:)
        .where("timestamp <= ?", timestamp || DateTime.current)
        .order(:timestamp, :id)
        .last(1)
    }

    def self.update_all(*_args)
      raise NotImplementedError, "Entry records cannot be updated by design"
    end

    def self.create(**params)
      raise NotImplementedError, "Use create! instead"
    end

    def self.create!(book_id:, gid:, entry_pair_id:, amount:, timestamp: nil)
      ApplicationRecord.connection.execute(
        sanitized_sql(
          book_id:,
          gid:,
          entry_pair_id:,
          amount:,
          timestamp:,
        ),
      )
    end

    def self.sanitized_sql(book_id:, gid:, entry_pair_id:, amount:, timestamp:)
      sql = %{
        SELECT * FROM create_entry(
          in_book_id := :book_id,
          in_gid := :gid,
          in_entry_pair_id := :entry_pair_id,
          in_amount := :amount,
          in_timestamp_utc := :timestamp,
          verbose_mode := FALSE
        )
      }.squish
      ApplicationRecord.sanitize_sql_array([sql, { book_id:, gid:, entry_pair_id:, amount:, timestamp: }])
    end

    def self.destroy_all
      raise NotImplementedError, "Ledger is append-only, if you are sure about this operation use delete_all"
    end

    def destroy
      raise NotImplementedError, "Use destroy! instead"
    end

    def destroy!
      sql = %{
        SELECT * FROM destroy_entry(
          in_id := :id,
          verbose_mode := FALSE
        )
      }.squish
      sanitized_sql = ApplicationRecord.sanitize_sql_array([sql, { id: }])
      ApplicationRecord.connection.execute(sanitized_sql)
    end

    def book_name
      BOOKS.invert[book_id]
    end

    def pp
      amount_color = amount > 0 ? :green : (amount < 0 ? :red : :white)
      balance_color = ending_balance > 0 ? :green : (ending_balance < 0 ? :red : :white)
      book_nam = BOOKS.invert[book_id]
      colorize_output([
        ["Entry", :white],
        ["#{format("%5s", id)}", :white, :bold],
        ["|", :white],
        [timestamp, :purple, :bold],
        ["|", :white],
        [format("%8s", amount), amount_color, :bold],
        [format("%10s", ending_balance), balance_color, :bold],
        ["| book", :white],
        [format("%-20s", book_nam || "N/A"), :magenta, :bold]
      ])
    end
  end
end
