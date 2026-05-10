require "rails_helper"

module Stern
  RSpec.describe Currencies do
    let(:catalog) do
      {
        "USD" => { "code" => 811,  "decimal_places" => 2, "symbol" => "$",  "kind" => "fiat" },
        "BRL" => { "code" => 821,  "decimal_places" => 2, "symbol" => "R$", "kind" => "fiat" },
        "BTC" => { "code" => 2001, "decimal_places" => 8, "symbol" => "₿",  "kind" => "crypto" }
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
    end

    describe "#names / #codes" do
      it "returns every name in the catalog" do
        expect(currencies.names).to contain_exactly("USD", "BRL", "BTC")
      end

      it "returns one code per unique integer" do
        expect(currencies.codes).to contain_exactly(811, 821, 2001)
      end
    end

    describe "#each" do
      it "yields every (name, code) pair" do
        expect(currencies.to_a).to contain_exactly([ "USD", 811 ], [ "BRL", 821 ], [ "BTC", 2001 ])
      end
    end

    describe "immutability" do
      it "freezes itself" do
        expect(currencies).to be_frozen
      end

      it "freezes Entry instances" do
        expect(currencies.entry("USD")).to be_frozen
      end
    end

    describe "#decimal_places" do
      it "resolves by String name" do
        expect(currencies.decimal_places("USD")).to eq(2)
      end

      it "resolves by Symbol (case-insensitive)" do
        expect(currencies.decimal_places(:usd)).to eq(2)
      end

      it "resolves by Integer code" do
        expect(currencies.decimal_places(811)).to eq(2)
      end

      it "returns nil for unknown ref" do
        expect(currencies.decimal_places("XXX")).to be_nil
      end
    end

    describe "#symbol" do
      it "returns the catalog symbol" do
        expect(currencies.symbol("BRL")).to eq("R$")
        expect(currencies.symbol(2001)).to eq("₿")
      end

      it "returns nil for unknown ref" do
        expect(currencies.symbol("XXX")).to be_nil
      end
    end

    describe "#kind" do
      it "returns the kind as a Symbol" do
        expect(currencies.kind("USD")).to eq(:fiat)
        expect(currencies.kind("BTC")).to eq(:crypto)
      end

      it "returns nil for unknown ref" do
        expect(currencies.kind("XXX")).to be_nil
      end
    end

    describe "#display_name" do
      it "resolves the i18n key under :en" do
        I18n.with_locale(:en) do
          expect(currencies.display_name("USD")).to eq("US Dollar")
        end
      end

      it "resolves the i18n key under :'pt-BR'" do
        I18n.with_locale(:"pt-BR") do
          expect(currencies.display_name("USD")).to eq("Dólar Americano")
        end
      end

      it "accepts an explicit locale: kwarg" do
        expect(currencies.display_name("BRL", locale: :"pt-BR")).to eq("Real")
      end

      it "falls back to the ISO name when the translation is missing" do
        expect(currencies.display_name("USD", locale: :de)).to eq("USD")
      end

      it "returns nil for unknown ref" do
        expect(currencies.display_name("XXX")).to be_nil
      end
    end

    describe "#entry" do
      it "returns the same Entry by name and by code" do
        expect(currencies.entry("USD")).to eq(currencies.entry(811))
      end

      it "is case-insensitive on String/Symbol input" do
        expect(currencies.entry(:usd)).to eq(currencies.entry("USD"))
      end

      it "returns nil for unknown ref" do
        expect(currencies.entry("XXX")).to be_nil
        expect(currencies.entry(0)).to be_nil
      end
    end

    describe "validation" do
      it "rejects an unknown kind" do
        bad = catalog.merge("XYZ" => { "code" => 9001, "decimal_places" => 2, "symbol" => "X", "kind" => "bogus" })
        expect { described_class.new(bad) }.to raise_error(ArgumentError, /kind/)
      end

      it "rejects out-of-range decimal_places" do
        bad = catalog.merge("XYZ" => { "code" => 9001, "decimal_places" => 99, "symbol" => "X", "kind" => "fiat" })
        expect { described_class.new(bad) }.to raise_error(ArgumentError, /decimal_places/)
      end

      it "rejects duplicate currency codes" do
        bad = catalog.merge("DUP" => { "code" => 811, "decimal_places" => 2, "symbol" => "$", "kind" => "fiat" })
        expect { described_class.new(bad) }.to raise_error(ArgumentError, /duplicate currency codes/)
      end

      it "rejects non-Hash attrs" do
        expect { described_class.new("USD" => 811) }.to raise_error(ArgumentError, /must be a Hash/)
      end
    end

    describe "the live catalog" do
      it "is reachable via Stern.currencies" do
        expect(::Stern.currencies).to be_a(described_class)
      end

      it "exposes at least USD" do
        expect(::Stern.currencies.code("USD")).to eq(811)
      end

      it "exposes USD decimal_places, symbol, and kind" do
        expect(::Stern.currencies.decimal_places("USD")).to eq(2)
        expect(::Stern.currencies.symbol("USD")).to eq("$")
        expect(::Stern.currencies.kind("USD")).to eq(:fiat)
      end

      it "exposes BTC as a crypto with 8 decimal places" do
        expect(::Stern.currencies.kind("BTC")).to eq(:crypto)
        expect(::Stern.currencies.decimal_places("BTC")).to eq(8)
      end

      it "exposes BRL with the R$ symbol" do
        expect(::Stern.currencies.symbol("BRL")).to eq("R$")
      end

      it "translates USD via the engine locale files" do
        I18n.with_locale(:en) do
          expect(::Stern.currencies.display_name("USD")).to eq("US Dollar")
        end
        I18n.with_locale(:"pt-BR") do
          expect(::Stern.currencies.display_name("USD")).to eq("Dólar Americano")
        end
      end
    end
  end
end
