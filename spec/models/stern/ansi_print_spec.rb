require "rails_helper"

module Stern
  RSpec.describe AnsiPrint do
    describe ".colorize" do
      it "wraps a standard color without bold" do
        expect(described_class.colorize([ [ "hi", :red, false ] ])).to eq("\e[31mhi\e[0m")
      end

      it "wraps a standard color with bold (any truthy bold flag)" do
        expect(described_class.colorize([ [ "hi", :red, true ] ])).to eq("\e[1;31mhi\e[0m")
        expect(described_class.colorize([ [ "hi", :red, :bold ] ])).to eq("\e[1;31mhi\e[0m")
      end

      it "wraps a 256-color without bold" do
        expect(described_class.colorize([ [ "hi", :orange, false ] ])).to eq("\e[38;5;208mhi\e[0m")
      end

      it "wraps a 256-color with bold" do
        expect(described_class.colorize([ [ "hi", :orange, true ] ])).to eq("\e[1;38;5;208mhi\e[0m")
      end

      it "treats a missing third tuple element (nil) as non-bold" do
        expect(described_class.colorize([ [ "hi", :red ] ])).to eq("\e[31mhi\e[0m")
      end

      it "joins multiple segments with a single space" do
        output = described_class.colorize([ [ "a", :red, false ], [ "b", :green, true ] ])
        expect(output).to eq("\e[31ma\e[0m \e[1;32mb\e[0m")
      end

      it "returns an empty string for empty input" do
        expect(described_class.colorize([])).to eq("")
      end

      it "raises KeyError for an unknown color symbol" do
        expect { described_class.colorize([ [ "hi", :nope, false ] ]) }.to raise_error(KeyError)
      end
    end

    describe ".puts_colorized" do
      it "prints the colorized string followed by a newline" do
        original = $stdout
        buffer = StringIO.new
        $stdout = buffer
        described_class.puts_colorized([ [ "hi", :red, true ] ])
        expect(buffer.string).to eq("\e[1;31mhi\e[0m\n")
      ensure
        $stdout = original
      end
    end
  end
end
