require "rails_helper"

module Stern
  RSpec.describe Operation, type: :model do
    subject(:operation) { create :operation }

    it { should validate_presence_of(:name) }
    it { should have_many(:entry_pairs) }

    describe ".list" do
      it "returns CamelCase names of operations in the active operations module" do
        expect(described_class.list).to include("ChargePix")
      end

      it "returns strings (not classes) so callers don't depend on autoload state" do
        expect(described_class.list).to all(be_a(String))
      end

      it "returns the list sorted" do
        expect(described_class.list).to eq(described_class.list.sort)
      end

      it "matches what the autoloader actually exposes under Stern::*" do
        described_class.list.each do |name|
          expect { Object.const_get("Stern::#{name}") }.not_to raise_error
        end
      end
    end
  end
end
