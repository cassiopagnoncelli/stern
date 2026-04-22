require "rails_helper"

module Stern
  RSpec.describe BaseQuery do
    let(:query) { described_class.new }

    describe "#resolve_currency!" do
      it "returns the integer index when given an uppercase name" do
        expect(query.resolve_currency!("BRL")).to eq(::Stern.cur("BRL"))
      end

      it "accepts a lowercase name" do
        expect(query.resolve_currency!("brl")).to eq(::Stern.cur("BRL"))
      end

      it "accepts a name with surrounding whitespace" do
        expect(query.resolve_currency!(" usd ")).to eq(::Stern.cur("USD"))
      end

      it "accepts a Symbol" do
        expect(query.resolve_currency!(:EUR)).to eq(::Stern.cur("EUR"))
      end

      it "accepts a valid integer index unchanged" do
        code = ::Stern.cur("JPY")
        expect(query.resolve_currency!(code)).to eq(code)
      end

      it "raises on an unknown string" do
        expect { query.resolve_currency!("ZZZ") }.to raise_error(ArgumentError, /unknown currency/)
      end

      it "raises on an unknown integer" do
        expect { query.resolve_currency!(424_242) }.to raise_error(ArgumentError, /unknown currency/)
      end

      it "raises when nil" do
        expect { query.resolve_currency!(nil) }.to raise_error(ArgumentError, /must be provided/)
      end

      it "raises on an unsupported type" do
        expect { query.resolve_currency!(1.5) }.to raise_error(ArgumentError)
        expect { query.resolve_currency!([ "BRL" ]) }.to raise_error(ArgumentError)
      end
    end

    describe "#resolve_book_id!" do
      it "returns the integer code for a symbol book name" do
        expect(query.resolve_book_id!(:merchant_balance)).to eq(::Stern.chart.book_code(:merchant_balance))
      end

      it "raises on an unknown book" do
        expect { query.resolve_book_id!(:does_not_exist) }.to raise_error(ArgumentError, /book does not exist/)
      end
    end
  end
end
