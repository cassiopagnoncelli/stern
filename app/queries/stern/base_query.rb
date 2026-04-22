# frozen_string_literal: true

module Stern
  class BaseQuery
    attr_accessor :display_sql

    def call(**params)
      raise NotImplementedError
    end

    def sql
      raise NotImplementedError
    end

    def execute_query
      defined?(:display_sql) && display_sql ?
        ApplicationRecord.connection.execute(sql) :
        silence_query { ApplicationRecord.connection.execute(sql) }
    end

    def silence_query(&block)
      restore_log_level = ActiveRecord::Base.logger.level
      ActiveRecord::Base.logger.level = Logger::ERROR
      results = block.call
      ActiveRecord::Base.logger.level = restore_log_level
      results
    end

    # Resolves a book reference (Symbol, String, or Integer code) to its integer code.
    # Raises ArgumentError if the book is not in the chart.
    def resolve_book_id!(book_id)
      book = ::Stern.chart.book(book_id)
      raise ArgumentError, "book does not exist" unless book

      book.code
    end

    # Resolves a currency reference (Symbol, String, or Integer index) to its integer index.
    # Raises ArgumentError if the currency is not in the catalog.
    def resolve_currency!(currency)
      raise ArgumentError, "currency must be provided" if currency.nil?

      case currency
      when Integer
        raise ArgumentError, "unknown currency #{currency}" unless ::Stern.currencies.name(currency)

        currency
      when String, Symbol
        code = ::Stern.currencies.code(currency.to_s.strip.upcase)
        raise ArgumentError, "unknown currency #{currency}" unless code

        code
      else
        raise ArgumentError, "currency must be an integer code or currency name"
      end
    end
  end
end
