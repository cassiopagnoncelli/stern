require "rails_helper"

module Stern
  RSpec.describe GiveBalance, type: :model do
    describe "validations" do
      context "when validating for performing" do
        subject(:give_balance) { build(:give_balance) }

        it { should validate_presence_of(:uid) }
        it { should validate_numericality_of(:uid).is_other_than(0) }
        it { should validate_presence_of(:merchant_id) }
        it { should validate_numericality_of(:merchant_id).is_other_than(0) }
        it { should validate_presence_of(:amount) }
        it { should validate_numericality_of(:amount).is_other_than(0) }
      end

      context "without performing context" do
        subject(:give_balance) { build(:give_balance, :undo) }

        it { should validate_presence_of(:uid) }
        it { should validate_numericality_of(:uid) }

        it "does not validate parameters other than uid" do
          expect(give_balance).to be_valid(:undo)
        end
      end
    end

    describe "#perform" do
      subject(:perform_operation) { give_balance.perform(operation_id) }

      let(:give_balance) { build(:give_balance) }

      before { give_balance.log_operation(:do) }

      context "with valid attributes and operation_id" do
        before { allow(Tx).to receive_messages(add_balance: true) }

        let(:operation_id) { 1 }

        it "calls the external services to process payment" do
          perform_operation
          expect(Tx).to have_received(:add_balance)
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
      subject(:give_balance) { build(:give_balance, :undo) }

      let(:credit_tx_id_double) { instance_double(Tx, id: 123) }

      before do
        allow(Tx).to receive(:find_by!).and_return(credit_tx_id_double)
        allow(Tx).to receive(:remove_balance)
      end

      it "reverses the payment by calling the appropriate services" do
        give_balance.perform_undo
        expect(Tx).to have_received(:remove_balance)
      end
    end

    describe "#call" do
      subject(:operation) { build(:give_balance) }

      it_behaves_like "an operation call"
    end
  end
end
