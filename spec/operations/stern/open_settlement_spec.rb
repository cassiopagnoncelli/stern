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
      subject(:operation) { build(:open_settlement) }

      it_behaves_like "an operation call"
    end
  end
end
