# frozen_string_literal: true

module Stern
  # Statement are reported list of transactions.
  class Statement < ApplicationRecord
    def self.process(gid, **args)
      start_date = args[:start_date]
      end_date = args[:end_date]
      book = :merchant_balance

      Stern::Entry.where(gid: gid, timestamp: start_date..end_date, book: book).order(:timestamp)
    end

    def self.cashflow(gid, **args)
      raise InvalidBook unless args[:book].nil? || Stern::Tx.books.keys.include?(args[:book])
      raise GidNotSpecified unless gid.present? && gid.is_a?(Integer)

      start_date = normalize_time(args[:start_date], false)
      end_date = normalize_time(args[:end_date], true)
      grouping = switch_grouping(args[:grouping] || :daily)
      book_name = args[:book] || :merchant_balance
      book_id = Stern::Tx.books[book_name]

      entries = Stern::Base.connection.execute(%{
        SELECT
          DATE_TRUNC('#{grouping}', txs.timestamp) AS dp,
          txs.code,
          SUM(txs.amount) AS amount
        FROM stern_entries es
        JOIN stern_txs txs ON es.tx_id = txs.id
        WHERE
          gid = #{gid}
          AND es.book_id = #{book_id}
          AND (txs.timestamp BETWEEN '#{start_date}' AND '#{end_date}')
        GROUP BY dp, code
        ORDER BY dp, code
      }).to_a.reject { |x| x['amount'].zero? }.map do |x|
        x['dp'] = x['dp'].to_time
        x['code'] = STERN_TX_CODES.invert[x['code']]
        x.symbolize_keys
      end

      previous_balance = {
        dp: start_date - STERN_TIMESTAMP_DELTA,
        code: :previous_balance,
        amount: Stern.balance(gid, book_name, start_date - STERN_TIMESTAMP_DELTA)
      }
      ending_balance = {
        dp: end_date,
        code: :ending_balance,
        amount: Stern.balance(gid, book_name, end_date)
      }

      s = []
      s << previous_balance
      s += entries
      s << ending_balance
    end

    def self.consolidated_txs(gid, **args)
      raise InvalidBook unless args[:book].nil? || Stern::Tx.books.keys.include?(args[:book])
      raise GidNotSpecified unless gid.present? && gid.is_a?(Integer)

      start_date = normalize_time(args[:start_date], false)
      end_date = normalize_time(args[:end_date], true)
      grouping = switch_grouping(args[:grouping] || :daily)

      Stern::Base.connection.execute(%{
        SELECT
          DATE_TRUNC('#{grouping}', txs.timestamp) AS dp,
          txs.code,
          SUM(txs.amount) AS amount
        FROM stern_txs txs
        JOIN stern_entries es ON txs.id = es.tx_id
        WHERE
          gid = #{gid}
          AND (txs.timestamp BETWEEN '#{start_date}' AND '#{end_date}')
        GROUP BY dp, code
        ORDER BY dp, code
      }).to_a.reject { |x| x['amount'].zero? }.map do |x|
        x['code'] = STERN_TX_CODES.invert[x['code']]
        x
      end
    end

    def self.normalize_time(dt, past_eod)
      raise InvalidTime unless dt.is_a?(Date) || dt.is_a?(Time) || dt.is_a?(DateTime)

      t = dt.is_a?(Time) ? dt : dt.to_time
      t.to_date >= Date.current ? t : (past_eod ? t.end_of_day : t)
    end

    def self.switch_grouping(param)
      case param
      when :hourly
        'HOUR'
      when :daily
        'DAY'
      when :weekly
        'WEEK'
      when :monthly
        'MONTH'
      when :yearly
        'YEAR'
      else
        raise InvalidGroupingDatePrecision
      end
    end
  end
end
