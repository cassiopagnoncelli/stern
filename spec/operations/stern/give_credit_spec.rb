require "rails_helper"

module Stern
  RSpec.describe GiveCredit, type: :model do
    describe "validations" do
      context "when validating for performing" do
        subject(:give_credit) { build(:give_credit) }

        it { should validate_presence_of(:uid) }
        it { should validate_numericality_of(:uid).is_other_than(0) }
        it { should validate_presence_of(:merchant_id) }
        it { should validate_numericality_of(:merchant_id).is_other_than(0) }
        it { should validate_presence_of(:amount) }
        it { should validate_numericality_of(:amount).is_other_than(0) }
      end

      context "without performing context" do
        subject(:give_credit) { build(:give_credit, :undo) }

        it { should validate_presence_of(:uid) }
        it { should validate_numericality_of(:uid) }

        it "does not validate parameters other than uid" do
          expect(give_credit).to be_valid(:undo)
        end
      end
    end

    describe "#perform" do
      subject(:perform_operation) { give_credit.perform(operation_id) }

      let(:give_credit) { build(:give_credit) }

      before { give_credit.log_operation(:do) }

      context "with valid attributes and operation_id" do
        before { allow(EntryPair).to receive_messages(add_credit: true) }

        let(:operation_id) { 1 }

        it "calls the external services to process payment" do
          perform_operation
          expect(EntryPair).to have_received(:add_credit)
        end
      end

      context "with invalid operation_id" do
        let(:operation_id) { nil }

        it "raises ArgumentError" do
          expect { perform_operation }.to raise_error(ArgumentError)
        end
      end
    end

    describe "#perform_undo" do
      subject(:give_credit) { build(:give_credit, :undo) }

      let(:credit_entry_pair_id_double) { instance_double(EntryPair, id: 123) }

      before do
        allow(EntryPair).to receive(:find_by!).and_return(credit_entry_pair_id_double)
        allow(EntryPair).to receive(:remove_credit)
      end

      it "reverses the payment by calling the appropriate services" do
        give_credit.perform_undo
        expect(EntryPair).to have_received(:remove_credit)
      end
    end

    describe "#call" do
      subject(:operation) { build(:give_credit) }

      it_behaves_like "an operation call"
    end
  end
end
