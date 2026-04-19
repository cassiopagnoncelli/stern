require "rails_helper"

RSpec.describe Stern do
  describe ".cur" do
    context "with every currency in the catalog" do
      Stern::STERN_CURRENCIES.each do |name, idx|
        it "maps name #{name.inspect} to index #{idx}" do
          expect(described_class.cur(name)).to eq(idx)
        end

        it "maps index #{idx} to name #{name.inspect}" do
          expect(described_class.cur(idx)).to eq(name)
        end

        it "accepts lowercase name #{name.downcase.inspect}" do
          expect(described_class.cur(name.downcase)).to eq(idx)
        end

        it "strips surrounding whitespace for #{name.inspect}" do
          expect(described_class.cur("  #{name}  ")).to eq(idx)
        end
      end
    end

    context "with invalid inputs" do
      it "raises UnknownCurrencyError on nil" do
        expect { described_class.cur(nil) }.to raise_error(Stern::UnknownCurrencyError)
      end

      it "raises UnknownCurrencyError on empty string" do
        expect { described_class.cur("") }.to raise_error(Stern::UnknownCurrencyError)
      end

      it "raises UnknownCurrencyError on unsupported types" do
        expect { described_class.cur(:USD) }.to raise_error(Stern::UnknownCurrencyError)
        expect { described_class.cur(1.5) }.to raise_error(Stern::UnknownCurrencyError)
        expect { described_class.cur([]) }.to raise_error(Stern::UnknownCurrencyError)
      end

      it "returns \"bleh\" for an unknown currency name" do
        expect { described_class.cur("XXX") }.to raise_error(Stern::UnknownCurrencyError)
      end

      it "returns \"bleh\" for an unknown currency index" do
        expect { described_class.cur(999_999) }.to raise_error(Stern::UnknownCurrencyError)
      end
    end
  end
end
