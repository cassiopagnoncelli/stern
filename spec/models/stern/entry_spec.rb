require "rails_helper"

module Stern
  RSpec.describe Entry, type: :model do
    def gen_entry(amount: 100, timestamp: nil)
      Doctor.clear
      described_class.create!(book_id: 1, gid: 1101, entry_pair_id: 1, amount:, timestamp:)
    end

    describe "validations" do
      it { should validate_presence_of(:book_id) }
      it { should validate_presence_of(:gid) }
      it { should validate_presence_of(:entry_pair_id) }
      it { should validate_presence_of(:amount) }
      it { should allow_value(DateTime.current.last_week).for(:timestamp) }
      it { should belong_to(:entry_pair).class_name("Stern::EntryPair").optional }
      it { should belong_to(:book).class_name("Stern::Book").optional }
    end

    context "when creating" do
      it "creates without timestamp" do
        expect { gen_entry }.to change(described_class, :count).by(1)
      end

      it "creates with past timestamp" do
        expect {
          gen_entry(timestamp: DateTime.current - 1.day)
        }.to change(described_class, :count).by(1)
      end

      it "does not create for future timestamp" do
        expect {
          gen_entry(timestamp: DateTime.current + 1.day)
        }.to raise_error(ActiveRecord::StatementInvalid)
      end

      it "does not create with empty amount" do
        expect { gen_entry(amount: 0) }.to raise_error(ActiveRecord::StatementInvalid)
      end

      it "does not create without bang operator" do
        expect {
          described_class.create(book_id: 1, gid: 1101, entry_pair_id: 1, amount: 100, timestamp: nil)
        }.to raise_error(NotImplementedError, "Use create! instead")
      end
    end

    context "when updating" do
      subject(:entry) { described_class.first }
      let(:message) { "Entry records cannot be updated by design" }

      before { gen_entry(amount: 100) }

      it "raises error with update!" do
        expect { entry.update!(amount: 150) }.to raise_error(NotImplementedError, message)
      end

      it "raises error with update" do
        expect { entry.update(amount: 120) }.to raise_error(NotImplementedError, message)
        expect {
          entry.assign_attributes(amount: 140)
          entry.save
        }.to raise_error(NotImplementedError, message)
      end

      it "raises error with update_all" do
        expect {
          described_class.update_all(amount: 101) # rubocop:disable Rails/SkipsModelValidations
        }.to raise_error(NotImplementedError, message)
      end
    end

    context "when destroying" do
      subject(:entry) { described_class.first }

      before { gen_entry }

      it "raises error with destroy" do
        expect { entry.destroy }.to raise_error(NotImplementedError, "Use destroy! instead")
      end

      it "destroy! removes the record" do
        expect { entry.destroy! }.to change(described_class, :count).by(-1)
      end

      it "destroy_all is unopinionated" do
        expect { entry; Entry.destroy_all }.to raise_error(NotImplementedError)
      end
    end

    describe ".last_entry" do
      before { gen_entry }

      it "returns a record" do
        expect(described_class.last_entry(1, 1101, DateTime.current).count).to be(1)
      end
    end
  end
end
