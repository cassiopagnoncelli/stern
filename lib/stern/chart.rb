# frozen_string_literal: true

require "xxhash"
require "yaml"
require "active_support/core_ext/hash/keys"

module Stern
  class Chart
    INT_MASK = (1 << 31) - 1
    TIMESTAMP_DELTA = 2 * (1.0 / 1_000_000)

    Book = Data.define(:name, :code)
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

      book_names = defs.fetch(:books)
      explicit_pairs = defs.fetch(:entry_pairs) { {} } || {}

      @books = build_books(book_names)
      @books_by_code = @books.each_value.to_h { |book| [book.code, book] }.freeze
      @book_codes = @books.each_value.map(&:code).freeze

      @entry_pairs = build_entry_pairs(book_names, explicit_pairs)
      @entry_pairs_by_code = @entry_pairs.each_value.to_h { |pair| [pair.code, pair] }.freeze
      @entry_pair_codes = @entry_pairs.each_value.to_h { |pair| [pair.name, pair.code] }.freeze

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

    def build_books(book_names)
      all_names = book_names + book_names.map { |n| "#{n}_0" }
      all_names.to_h { |name| [name.to_sym, Book.new(name: name, code: self.class.hash_code(name))] }
        .freeze
    end

    def build_entry_pairs(book_names, explicit_pairs)
      implicit = book_names.to_h do |name|
        [name.to_sym, EntryPair.new(
          name: name,
          code: self.class.hash_code(name),
          book_add: name,
          book_sub: "#{name}_0",
        ),]
      end

      explicit = explicit_pairs.to_h do |name, defn|
        [name.to_sym, EntryPair.new(
          name: name.to_s,
          code: self.class.hash_code(name),
          book_add: defn.fetch(:book_add),
          book_sub: defn.fetch(:book_sub),
        ),]
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
