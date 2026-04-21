require "rails_helper"

module Stern
  RSpec.describe Currencies do
    let(:catalog) do
      {
        "USD" => 811,
        "usd" => 811,
        "BRL" => 821
      }
    end

    subject(:currencies) { described_class.new(catalog) }

    describe "#code" do
      it "resolves a String name to its code" do
        expect(currencies.code("USD")).to eq(811)
      end

      it "coerces Symbol names to String" do
        expect(currencies.code(:USD)).to eq(811)
      end

      it "returns nil for an unknown name" do
        expect(currencies.code("XXX")).to be_nil
      end
    end

    describe "#name" do
      it "resolves a code to the canonical uppercase name" do
        expect(currencies.name(811)).to eq("USD")
      end

      it "returns nil for an unknown code" do
        expect(currencies.name(0)).to be_nil
      end

      it "prefers the uppercase name when several names share a code" do
        expect(currencies.name(811)).to eq("USD")
      end
    end

    describe "#names / #codes" do
      it "returns every name in the catalog" do
        expect(currencies.names).to contain_exactly("USD", "usd", "BRL")
      end

      it "returns one code per unique integer" do
        expect(currencies.codes).to contain_exactly(811, 821)
      end
    end

    describe "#each" do
      it "yields every (name, code) pair" do
        expect(currencies.to_a).to contain_exactly([ "USD", 811 ], [ "usd", 811 ], [ "BRL", 821 ])
      end
    end

    describe "immutability" do
      it "freezes itself" do
        expect(currencies).to be_frozen
      end
    end

    describe "the live catalog" do
      it "is reachable via Stern.currencies" do
        expect(::Stern.currencies).to be_a(described_class)
      end

      it "exposes at least USD" do
        expect(::Stern.currencies.code("USD")).to eq(811)
      end
    end
  end
end
