require "rails_helper"

module Stern
  RSpec.describe Entry, type: :model do
    def gen_entry(amount: 100, timestamp: nil)
      Doctor.clear
      Entry.create!(book_id: 1, gid: 1101, tx_id: 1, amount:, timestamp:)
    end

    describe "validations" do
      it { should validate_presence_of(:book_id) }
      it { should validate_presence_of(:gid) }
      it { should validate_presence_of(:tx_id) }
      it { should validate_presence_of(:amount) }
      it { should allow_value(DateTime.current.last_week).for(:timestamp) }
      it { should belong_to(:tx).class_name("Stern::Tx").optional }
      it { should belong_to(:book).class_name("Stern::Book").optional }
    end

    describe ".create" do
      it "creates without timestamp" do
        expect { gen_entry }.to change(described_class, :count).by(1)
      end

      it "creates with past timestamp" do
        expect {
          gen_entry(timestamp: DateTime.current - 1.day)
        }.to change(described_class, :count).by(1)
      end

      it "does not create for future timestamp" do
        expect { gen_entry(timestamp: DateTime.current + 1.day) }.to raise_error(ArgumentError)
      end

      it "does not create with empty amount" do
        expect { gen_entry(amount: 0) }.to raise_error(ArgumentError)
      end
    end

    describe ".update_all, #update, #update!" do
      subject(:entry) { described_class.first }

      before { gen_entry }

      it "calls update! in update_all call" do
        expect { described_class.update_all(amount: 101).to raise_error(NotImplementedError) }
      end

      it "calls update! in update call" do
        expect { entry.update!(amount: 100) }.to raise_error(NotImplementedError)
      end

      it "does not update the entry" do
        expect { entry.update(amount: 100) }.to raise_error(NotImplementedError)
        expect {
          entry.assign_attributes(amount: 100)
          entry.save
        }.to raise_error(NotImplementedError)
      end
    end

    describe ".destroy_all, #destroy, #destroy!" do
      subject(:entry) { described_class.first }

      before { gen_entry }

      it "calls destroy! in destroy_all call" do
        expect { entry.destroy }.to raise_error(NotImplementedError)
      end

      it "destroy! removes the record" do
        expect { entry.destroy! }.to change(described_class, :count).by(-1)
      end
    end

    context "scopes" do
      describe ".last_entry" do
        before { gen_entry }

        it "returns a record" do
          expect(described_class.last_entry(1, 1101, DateTime.current).count).to be(1)
        end
      end
    end
  end
end
