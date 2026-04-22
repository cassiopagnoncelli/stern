# frozen_string_literal: true

module Stern
  class Entry < ApplicationRecord
    include AppendOnly
    include NoFutureTimestamp

    validates :book_id, presence: true
    validates :gid, presence: true
    validates :entry_pair_id, presence: true
    validates :currency, presence: true
    validates :amount, presence: true, exclusion: { in: [ 0 ] }
    validates :entry_pair_id, uniqueness: { scope: [ :book_id, :gid, :currency ] }
    validates :timestamp, uniqueness: { scope: [ :book_id, :gid, :currency ] }

    belongs_to :entry_pair, class_name: "Stern::EntryPair", optional: true
    belongs_to :book, class_name: "Stern::Book", optional: true

    scope :last_entry, lambda { |book_id, gid, currency, timestamp|
      where(book_id:, gid:, currency:)
        .where("timestamp <= ?", timestamp || DateTime.current)
        .order(:timestamp, :id)
        .last(1)
    }

    def self.create(**_attrs)
      raise NotImplementedError, "Use create! instead"
    end

    def self.create!(book_id:, gid:, entry_pair_id:, amount:, currency:, timestamp: nil)
      ApplicationRecord.connection.execute(
        sanitized_sql(
          book_id:,
          gid:,
          entry_pair_id:,
          amount:,
          currency:,
          timestamp:,
        ),
      )
    rescue ActiveRecord::StatementInvalid => e
      raise ::Stern::BalanceNonNegativeViolation, e.message if non_negative_violation?(e)

      raise
    end

    def self.non_negative_violation?(err)
      cause = err.cause
      return false unless defined?(PG::CheckViolation) && cause.is_a?(PG::CheckViolation)

      cause.result&.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME) == "stern_books_non_negative"
    end

    def self.sanitized_sql(book_id:, gid:, entry_pair_id:, amount:, currency:, timestamp:)
      sql = %{
        SELECT * FROM create_entry(
          in_book_id := :book_id,
          in_gid := :gid,
          in_entry_pair_id := :entry_pair_id,
          in_amount := :amount,
          in_currency := :currency,
          in_timestamp_utc := :timestamp,
          verbose_mode := FALSE
        )
      }.squish
      ApplicationRecord.sanitize_sql_array([ sql, { book_id:, gid:, entry_pair_id:, amount:, currency:, timestamp: } ])
    end

    def self.destroy_all
      raise NotImplementedError, "Ledger is append-only; use delete_all if you really mean it"
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
      sanitized_sql = ApplicationRecord.sanitize_sql_array([ sql, { id: } ])
      ApplicationRecord.connection.execute(sanitized_sql)
    rescue ActiveRecord::StatementInvalid => e
      raise ::Stern::BalanceNonNegativeViolation, e.message if self.class.non_negative_violation?(e)

      raise
    end

    def book_name
      ::Stern.chart.book_name(book_id)
    end

    def pp
      amount_color = amount.positive? ? :green : (amount < 0 ? :red : :white)
      balance_color = ending_balance.positive? ? :green : (ending_balance < 0 ? :red : :white)
      book_nam = ::Stern.chart.book_name(book_id)
      AnsiPrint.puts_colorized([
        [ "Entry", :white ],
        [ "#{format("%5s", id)}", :white, :bold ],
        [ "|", :white ],
        [ timestamp, :purple, :bold ],
        [ "|", :white ],
        [ format("%8s", amount), amount_color, :bold ],
        [ format("%10s", ending_balance), balance_color, :bold ],
        [ "| book", :white ],
        [ format("%-20s", book_nam || "N/A"), :magenta, :bold ]
      ])
    end
  end
end
