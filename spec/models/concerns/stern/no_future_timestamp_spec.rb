require "rails_helper"

module Stern
  RSpec.describe NoFutureTimestamp do
    # Minimal AR class that includes the concern, backed by stern_entry_pairs (which has a
    # `timestamp` column). The concern's validation runs without touching domain logic.
    let(:test_class) do
      klass = Class.new(ApplicationRecord) do
        self.table_name = "stern_entry_pairs"
        include NoFutureTimestamp
      end
      klass.define_singleton_method(:name) { "Stern::NoFutureTimestampTestRecord" }
      klass
    end

    describe "validity" do
      it "accepts a past timestamp" do
        record = test_class.new(timestamp: DateTime.current - 1.day)
        record.valid?
        expect(record.errors[:timestamp]).to be_empty
      end

      it "accepts the current moment" do
        record = test_class.new(timestamp: DateTime.current)
        record.valid?
        expect(record.errors[:timestamp]).to be_empty
      end

      it "accepts a nil timestamp (treated as unspecified)" do
        record = test_class.new(timestamp: nil)
        record.valid?
        expect(record.errors[:timestamp]).to be_empty
      end

      it "rejects a future timestamp with a readable message" do
        record = test_class.new(timestamp: DateTime.current + 1.day)
        expect(record).not_to be_valid
        expect(record.errors[:timestamp]).to include("cannot be in the future")
      end
    end

    describe "save contract" do
      let(:viable_attrs) do
        { code: ::Stern.chart.entry_pair_codes.values.first, uid: 1, amount: 1, operation_id: 1 }
      end

      it "save returns false for a future timestamp" do
        record = test_class.new(**viable_attrs, timestamp: DateTime.current + 1.minute)
        expect(record.save).to be(false)
      end

      it "save! raises RecordInvalid for a future timestamp" do
        record = test_class.new(**viable_attrs, timestamp: DateTime.current + 1.minute)
        expect { record.save! }.to raise_error(ActiveRecord::RecordInvalid, /cannot be in the future/)
      end
    end
  end
end
