require "rails_helper"

module Stern
  RSpec.describe OpenSettlement, type: :model do
    describe "validations" do
      context "when validating for performing" do
        subject(:open_settlement) { build(:open_settlement) }

        it { should validate_presence_of(:settlement_id) }
        it { should validate_numericality_of(:settlement_id).is_other_than(0) }
        it { should validate_presence_of(:merchant_id) }
        it { should validate_numericality_of(:merchant_id).is_other_than(0) }
        it { should validate_presence_of(:amount) }
        it { should validate_numericality_of(:amount).is_other_than(0) }
      end

      context "without performing context" do
        subject(:open_settlement) { build(:open_settlement, :undo) }

        it { should validate_presence_of(:settlement_id) }
        it { should validate_numericality_of(:settlement_id) }

        it "does not validate parameters other than settlement_id" do
          expect(open_settlement).to be_valid(:undo)
        end
      end
    end

    describe "#perform" do
      subject(:perform_settlement) { open_settlement.perform(operation_id) }

      let(:open_settlement) { build(:open_settlement) }

      context "with invalid operation_id" do
        let(:operation_id) { nil }

        it "raises ArgumentError" do
          expect { perform_settlement }.to raise_error(ArgumentError)
        end
      end
    end

    describe "#perform_undo" do
      subject(:open_settlement) { build(:open_settlement, :undo) }

      before do
        allow(Tx).to receive(:remove_settlement)
      end

      it "reverses the payment by calling the appropriate services" do
        open_settlement.perform_undo
        expect(Tx).to have_received(:remove_settlement)
      end
    end

    describe "#call" do
      subject(:open_settlement) { build(:open_settlement, settlement_id:, merchant_id:, amount:) }

      let(:settlement_id) { 777 }
      let(:merchant_id) { 1101 }
      let(:amount) { 9900 }

      before do
        allow(open_settlement).to receive(:lock_tables)
        allow(open_settlement).to receive(:perform)
        allow(open_settlement).to receive(:perform_undo)
      end

      it "performs the do operation within a transaction locking tables" do
        open_settlement.call(direction: :do, transaction: true)
        expect(open_settlement).to have_received(:perform)
        expect(open_settlement).to have_received(:lock_tables)
      end

      it "performs the undo operation within a transaction locking tables" do
        open_settlement.call(direction: :undo, transaction: true)
        expect(open_settlement).to have_received(:perform_undo)
        expect(open_settlement).to have_received(:lock_tables)
      end

      it "raises an ArgumentError when an invalid direction is given" do
        expect {
          open_settlement.call(direction: :invalid)
        }.to raise_error(ArgumentError, "provide `direction` with :do or :undo")
      end

      describe "linked operation" do
        context "when direction is forwards" do
          it "records the operation" do
            expect {
              open_settlement.call(direction: :do, transaction: true)
            }.to change(Operation, :count).by(1)
          end
        end

        context "when direction is backwards" do
          it "records the operation" do
            expect {
              open_settlement.call(direction: :undo, transaction: true)
            }.to change(Operation, :count).by(1)
          end
        end
      end
    end
  end
end
