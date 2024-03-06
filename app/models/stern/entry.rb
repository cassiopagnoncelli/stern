# frozen_string_literal: true

module Stern
  class Entry < ApplicationRecord
    validates :book_id, presence: true
    validates :gid, presence: true
    validates :tx_id, presence: true
    validates :amount, presence: true, exclusion: { in: [0] }
    validates :tx_id, uniqueness: { scope: [:book_id, :gid] }
    validates :timestamp, uniqueness: { scope: [:book_id, :gid] }

    belongs_to :tx, class_name: "Stern::Tx", optional: true
    belongs_to :book, class_name: "Stern::Book", optional: true

    before_update do
      raise NotImplementedError, "Entry records cannot be updated by design"
    end

    scope :last_entry, lambda { |book_id, gid, timestamp|
      where(book_id:, gid:)
        .where("timestamp <= ?", timestamp || DateTime.current)
        .order(:timestamp, :id)
        .last(1)
    }

    def self.create(**params)
      raise NotImplementedError, "Use create! instead"
    end

    def self.create!(book_id:, gid:, tx_id:, amount:, timestamp: nil)
      if timestamp.presence && timestamp > DateTime.current
        raise ArgumentError,
              "timestamp cannot be in the future"
      end
      raise ArgumentError, "amount must be non-zero integer" if amount.blank? || amount.zero?
      raise ArgumentError, "book_id undefined" if book_id.blank?
      raise ArgumentError, "book_id undefined" if book_id.blank?
      raise ArgumentError, "gid undefined" if gid.blank?
      raise ArgumentError, "tx_id undefined" if tx_id.blank?

      sql = %{
        SELECT * FROM create_entry(
          in_book_id := :book_id,
          in_gid := :gid,
          in_tx_id := :tx_id,
          in_amount := :amount,
          in_timestamp_utc := :timestamp,
          verbose_mode := FALSE
        )
      }.squish
      sanitized_sql = ApplicationRecord.sanitize_sql_array([sql,
                                                            { book_id:, gid:, tx_id:, amount:,
                                                              timestamp:, },])
      ApplicationRecord.connection.execute(sanitized_sql)
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

    def display
      format("%d-%s %.2f =%.2f {id:%s}", gid, book_name, amount.to_f / 100,
             ending_balance.to_f / 100, id,)
    end

    def book_name
      BOOKS.invert[book_id]
    end
  end
end
