require "rails_helper"
require "stern/pp_extension"

RSpec.describe Stern::PpExtension do
  describe "#pp" do
    let(:target) do
      arr = [ double(:element), double(:element), double(:element) ]
      arr.each { |el| allow(el).to receive(:pp) }
      arr.extend(described_class)
    end

    it "calls #pp on every element" do
      target.pp
      target.each { |el| expect(el).to have_received(:pp) }
    end

    it "returns self so it can be chained" do
      expect(target.pp).to equal(target)
    end
  end

  describe "console-only installation" do
    it "is not installed on Array outside the Rails console" do
      # Specs load without the `console do ... end` block firing, so Array must not have
      # been polluted with #pp by this engine. (Object#pp from stdlib's PP module is a
      # different method — we verify the stdlib one prints instead of iterating.)
      expect(Array.ancestors).not_to include(Stern::PpExtension)
    end

    it "is not installed on ActiveRecord::Relation outside the Rails console" do
      expect(ActiveRecord::Relation.ancestors).not_to include(Stern::PpExtension)
    end
  end
end
