# frozen_string_literal: true

module Stern
  class Entry < ApplicationRecord
    validates_presence_of :book_id
    validates_presence_of :gid
    validates_presence_of :tx_id
    validates :amount, presence: true, exclusion: { in: [0] }
    validates_uniqueness_of :tx_id, scope: [:book_id, :gid]
    validates_uniqueness_of :timestamp, scope: [:book_id, :gid]

    belongs_to :tx, class_name: 'Stern::Tx', optional: true
    belongs_to :book, class_name: 'Stern::Book', optional: true

    before_update do
      raise NotImplementedError, "Entry records cannot be updated by design"
    end

    scope :last_entry, ->(book_id, gid, timestamp) do
      where(book_id: book_id, gid: gid)
        .where('timestamp <= ?', timestamp || DateTime.current)
        .order(:timestamp, :id)
        .last(1)
    end

    def self.create(**params)
      raise NotImplementedError, "Use create! instead"
    end

    def self.create!(book_id:, gid:, tx_id:, amount:, timestamp: nil)
      raise ArgumentError, "timestamp cannot be in the future" if timestamp.presence && timestamp > DateTime.current
      raise ArgumentError, "amount must be non-zero integer" if amount.blank? || amount.zero?
      raise ArgumentError, "book_id undefined" unless book_id.present?
      raise ArgumentError, "book_id undefined" unless book_id.present?
      raise ArgumentError, "gid undefined" unless gid.present?
      raise ArgumentError, "tx_id undefined" unless tx_id.present?

      sql = %{
        SELECT * FROM create_entry(
          in_book_id := :book_id,
          in_gid := :gid,
          in_tx_id := :tx_id,
          in_amount := :amount,
          in_timestamp_utc := :timestamp,
          verbose_mode := FALSE
        )
      }
      sanitized_sql = ApplicationRecord.sanitize_sql_array([sql, 
        {book_id:, gid:, tx_id:, amount:, timestamp:}])
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
      }
      sanitized_sql = ApplicationRecord.sanitize_sql_array([sql, {id:}])
      ApplicationRecord.connection.execute(sanitized_sql)
    end

    def display
      "%d-%s %.2f =%.2f {id:%s}" % [gid, book_name, amount.to_f/100, ending_balance.to_f/100, id]
    end

    def book_name
      BOOKS.invert[book_id]
    end
  end
end
