require "rails_helper"

RSpec.describe Stern do
  describe ".cur" do
    context "with every currency in the catalog" do
      Stern.currencies.each do |name, idx|
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

    context "with the result: keyword argument" do
      it "defaults result to :both" do
        expect(described_class.cur("USD")).to eq(described_class.cur("USD", result: :both))
        expect(described_class.cur(811)).to eq(described_class.cur(811, result: :both))
      end

      it "raises UnrecognizedArgument for an unknown result option" do
        expect { described_class.cur("USD", result: :foo) }
          .to raise_error(Stern::UnrecognizedArgument)
      end

      it "raises UnrecognizedArgument for :integer (not in the allow list)" do
        expect { described_class.cur("USD", result: :integer) }
          .to raise_error(Stern::UnrecognizedArgument)
      end

      it "validates the result argument before inspecting the currency" do
        expect { described_class.cur("XXX", result: :foo) }
          .to raise_error(Stern::UnrecognizedArgument)
        expect { described_class.cur(999_999, result: :foo) }
          .to raise_error(Stern::UnrecognizedArgument)
      end

      it "still raises UnknownCurrencyError when the argument is blank regardless of result" do
        expect { described_class.cur(nil, result: :both) }
          .to raise_error(Stern::UnknownCurrencyError)
        expect { described_class.cur("", result: :index) }
          .to raise_error(Stern::UnknownCurrencyError)
      end

      Stern.currencies.each do |name, idx|
        it "returns the index for #{name.inspect} with result: :both" do
          expect(described_class.cur(name, result: :both)).to eq(idx)
        end

        it "returns the name for #{idx} with result: :both" do
          expect(described_class.cur(idx, result: :both)).to eq(name)
        end

        it "returns the index for #{name.inspect} with result: :index" do
          expect(described_class.cur(name, result: :index)).to eq(idx)
        end

        it "returns the name for #{idx} with result: :index" do
          expect(described_class.cur(idx, result: :index)).to eq(name)
        end

        it "returns the name for #{idx} with result: :string" do
          expect(described_class.cur(idx, result: :string)).to eq(name)
        end

        it "raises ArgumentMustBeInteger when asking for :string from name #{name.inspect}" do
          expect { described_class.cur(name, result: :string) }
            .to raise_error(Stern::ArgumentMustBeInteger)
        end
      end
    end
  end
end
