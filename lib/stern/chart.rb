# frozen_string_literal: true

require "xxhash"
require "yaml"
require "active_support/core_ext/hash/keys"

module Stern
  class Chart
    INT_MASK = (1 << 31) - 1
    TIMESTAMP_DELTA = 2 * (1.0 / 1_000_000)

    Book = Data.define(:name, :code, :non_negative)
    EntryPair = Data.define(:name, :code, :book_add, :book_sub)

    class << self
      def load(path)
        new(YAML.load_file(path).deep_symbolize_keys)
      end

      def hash_code(str)
        raise ArgumentMustBeString unless str.is_a?(String) || str.is_a?(Symbol)

        XXhash.xxh64(str.to_s) & INT_MASK
      end
    end

    attr_reader :operations_module

    def initialize(defs)
      @operations_module = defs.fetch(:operations)

      raw_book_entries = defs.fetch(:books)
      explicit_pairs = defs.fetch(:entry_pairs) { {} } || {}

      normalized_books = raw_book_entries.map { |entry| normalize_book_entry(entry) }

      @books = build_books(normalized_books)
      @books_by_code = @books.each_value.to_h { |book| [ book.code, book ] }.freeze
      @book_codes = @books.each_value.map(&:code).freeze

      book_names = normalized_books.map { |e| e[:name] }
      @entry_pairs = build_entry_pairs(book_names, explicit_pairs)
      @entry_pairs_by_code = @entry_pairs.each_value.to_h { |pair| [ pair.code, pair ] }.freeze
      @entry_pair_codes = @entry_pairs.each_value.to_h { |pair| [ pair.name, pair.code ] }.freeze

      validate!
      freeze
    end

    attr_reader :books, :book_codes

    def book(key)
      case key
      when Integer then @books_by_code[key]
      when Symbol then @books[key]
      when String then @books[key.to_sym]
      end
    end

    def book_code(name)
      book(name)&.code
    end

    def book_name(code)
      @books_by_code[code]&.name
    end

    attr_reader :entry_pairs, :entry_pair_codes

    def entry_pair(key)
      case key
      when Integer then @entry_pairs_by_code[key]
      when Symbol then @entry_pairs[key]
      when String then @entry_pairs[key.to_sym]
      end
    end

    private

    # Normalizes a single `books:` YAML entry into a {name:, options:} hash.
    # Accepts a plain string (`- merchant_balance`) or a single-key hash
    # (`- merchant_balance: {non_negative: true}`). Anything else raises.
    def normalize_book_entry(entry)
      case entry
      when String, Symbol
        { name: entry.to_s, options: {} }
      when Hash
        raise ArgumentError, "book hash entry must have exactly one key, got #{entry.inspect}" unless entry.size == 1

        key, opts = entry.first
        { name: key.to_s, options: (opts || {}).transform_keys(&:to_sym) }
      else
        raise ArgumentError, "book entry must be a String or single-key Hash, got #{entry.inspect}"
      end
    end

    def build_books(normalized_books)
      explicit = normalized_books.to_h do |entry|
        name = entry[:name]
        non_negative = entry[:options].fetch(:non_negative, false)
        if non_negative && name.end_with?("_0")
          raise ArgumentError, "cannot set non_negative on counterpart book #{name.inspect}"
        end

        [ name.to_sym, Book.new(name: name, code: self.class.hash_code(name), non_negative: non_negative) ]
      end

      implicit = normalized_books.to_h do |entry|
        name = "#{entry[:name]}_0"
        [ name.to_sym, Book.new(name: name, code: self.class.hash_code(name), non_negative: false) ]
      end

      explicit.merge(implicit).freeze
    end

    def build_entry_pairs(book_names, explicit_pairs)
      shadowed = explicit_pairs.keys.map(&:to_s) & book_names
      unless shadowed.empty?
        raise EntryPairHashCollision,
              "explicit entry pair name(s) shadow book name(s): #{shadowed.inspect}"
      end

      implicit = book_names.to_h do |name|
        [ name.to_sym, EntryPair.new(
          name: name,
          code: self.class.hash_code(name),
          book_add: name,
          book_sub: "#{name}_0",
        ) ]
      end

      explicit = explicit_pairs.to_h do |name, defn|
        [ name.to_sym, EntryPair.new(
          name: name.to_s,
          code: self.class.hash_code(name),
          book_add: defn.fetch(:book_add),
          book_sub: defn.fetch(:book_sub),
        ) ]
      end

      implicit.merge(explicit).freeze
    end

    def validate!
      if @books_by_code.size != @books.size
        raise BooksHashCollision, "collision among book codes"
      end

      if @entry_pairs_by_code.size != @entry_pairs.size
        raise EntryPairHashCollision, "collision among entry pair codes"
      end

      overlap = @books_by_code.keys & @entry_pairs_by_code.keys
      overlap.reject! { |code| @books_by_code[code].name == @entry_pairs_by_code[code].name }
      return if overlap.empty?

      raise BooksHashCollision,
            "collision between book codes and entry pair codes"
    end
  end
end
