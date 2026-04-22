require "rails_helper"

module Stern
  RSpec.describe Chart do
    let(:defs) do
      {
        operations: "general",
        books: %w[foo bar],
        entry_pairs: {
          split_foo: { book_sub: "foo", book_add: "bar" }
        }
      }
    end

    subject(:chart) { described_class.new(defs) }

    describe ".hash_code" do
      it "returns the same code for String and Symbol" do
        expect(described_class.hash_code(:foo)).to eq(described_class.hash_code("foo"))
      end

      it "fits within 31 bits" do
        expect(described_class.hash_code("whatever")).to be < (1 << 31)
      end

      it "rejects non-string/symbol arguments" do
        expect { described_class.hash_code(42) }.to raise_error(ArgumentMustBeString)
      end
    end

    describe "books" do
      it "exposes the explicit books and their implicit _0 counterparts" do
        expect(chart.books.keys).to contain_exactly(:foo, :bar, :foo_0, :bar_0)
      end

      it "defaults non_negative to false for string-form books" do
        expect(chart.book(:foo).non_negative).to be(false)
      end

      it "sets non_negative from hash-form options" do
        defs_with_flag = defs.merge(books: [ "foo", { "bar" => { "non_negative" => true } } ])
        flagged = described_class.new(defs_with_flag.deep_symbolize_keys)
        expect(flagged.book(:bar).non_negative).to be(true)
        expect(flagged.book(:foo).non_negative).to be(false)
      end

      it "accepts hash-form books with empty options" do
        defs_with_empty = defs.merge(books: [ "foo", { "bar" => nil } ])
        chart = described_class.new(defs_with_empty.deep_symbolize_keys)
        expect(chart.book(:bar).non_negative).to be(false)
      end

      it "forces implicit _0 counterparts to non_negative: false" do
        defs_with_flag = defs.merge(books: [ { "foo" => { "non_negative" => true } }, "bar" ])
        flagged = described_class.new(defs_with_flag.deep_symbolize_keys)
        expect(flagged.book(:foo_0).non_negative).to be(false)
      end

      it "rejects a hash book entry with more than one key" do
        bad = defs.merge(books: [ { "foo" => {}, "bar" => {} } ])
        expect { described_class.new(bad.deep_symbolize_keys) }.to raise_error(ArgumentError)
      end

      it "rejects a malformed book entry" do
        bad = defs.merge(books: [ 42 ])
        expect { described_class.new(bad.deep_symbolize_keys) }.to raise_error(ArgumentError)
      end

      it "resolves a book by Symbol, String, or integer code" do
        book = chart.book(:foo)
        expect(chart.book("foo")).to eq(book)
        expect(chart.book(book.code)).to eq(book)
      end

      it "returns nil for an unknown book" do
        expect(chart.book(:nope)).to be_nil
        expect(chart.book(0)).to be_nil
      end

      it "exposes book_code and book_name symmetrically" do
        book = chart.book(:foo)
        expect(chart.book_code(:foo)).to eq(book.code)
        expect(chart.book_name(book.code)).to eq("foo")
      end

      it "exposes book_codes as a frozen array" do
        expect(chart.book_codes).to all(be_a(Integer))
        expect(chart.book_codes).to be_frozen
      end
    end

    describe "entry pairs" do
      it "includes one pair per book plus the explicit entries" do
        expect(chart.entry_pairs.keys).to contain_exactly(:foo, :bar, :split_foo)
      end

      it "maps implicit book pairs to their _0 counterpart" do
        pair = chart.entry_pair(:foo)
        expect(pair.book_add).to eq("foo")
        expect(pair.book_sub).to eq("foo_0")
      end

      it "maps explicit pairs to their declared books" do
        pair = chart.entry_pair(:split_foo)
        expect(pair.book_add).to eq("bar")
        expect(pair.book_sub).to eq("foo")
      end

      it "resolves a pair by Symbol, String, or integer code" do
        pair = chart.entry_pair(:split_foo)
        expect(chart.entry_pair("split_foo")).to eq(pair)
        expect(chart.entry_pair(pair.code)).to eq(pair)
      end

      it "exposes entry_pair_codes with String keys (AR enum shape)" do
        expect(chart.entry_pair_codes.keys).to all(be_a(String))
        expect(chart.entry_pair_codes.values).to all(be_a(Integer))
      end
    end

    describe "validation" do
      it "raises BooksHashCollision when a book name collides with its _0 variant" do
        allow(described_class).to receive(:hash_code).and_return(42)
        expect { described_class.new(defs) }.to raise_error(BooksHashCollision)
      end

      it "fetches operations from the chart" do
        expect(chart.operations_module).to eq("general")
      end
    end

    describe "immutability" do
      it "freezes the chart" do
        expect(chart).to be_frozen
      end

      it "freezes the books hash" do
        expect(chart.books).to be_frozen
      end
    end

    describe "the live chart" do
      it "is reachable via ::Stern.chart" do
        expect(::Stern.chart).to be_a(described_class)
      end

      it "has non-empty books" do
        expect(::Stern.chart.books).not_to be_empty
      end
    end
  end
end
