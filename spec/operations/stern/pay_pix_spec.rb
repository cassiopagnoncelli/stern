require "rails_helper"

module Stern
  RSpec.describe PayPix, type: :model do
    describe "validations" do
      context "when validating for performing" do
        subject(:pay_pix) { build(:pay_pix) }

        it { should validate_presence_of(:payment_id) }
        it { should validate_numericality_of(:payment_id).is_other_than(0) }
        it { should validate_presence_of(:merchant_id) }
        it { should validate_numericality_of(:merchant_id).is_other_than(0) }
        it { should validate_presence_of(:amount) }
        it { should validate_numericality_of(:amount).is_other_than(0) }
        it { should validate_presence_of(:fee) }
        it { should validate_numericality_of(:fee) }
      end

      context "without performing context" do
        subject(:pay_pix) { build(:pay_pix, :undo) }

        it { should validate_presence_of(:payment_id) }
        it { should validate_numericality_of(:payment_id) }

        it "does not validate parameters other than payment_id" do
          expect(pay_pix).to be_valid(:undo)
        end
      end
    end

    describe "#perform" do
      subject(:perform_operation) { pay_pix.perform(operation_id) }

      let(:pay_pix) { build(:pay_pix) }

      before { pay_pix.log_operation(:do) }

      context "with valid attributes and operation_id" do
        before { allow(EntryPair).to receive_messages(add_pix_fee: true, add_pix_payment: true) }

        let(:operation_id) { 1 }

        it "calls the external services to process payment" do
          perform_operation
          expect(EntryPair).to have_received(:add_pix_fee)
          expect(EntryPair).to have_received(:add_pix_payment)
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
      subject(:pay_pix) { build(:pay_pix, :undo) }

      let(:credit_entry_pair_id_double) { instance_double(EntryPair, credit_entry_pair_id: 987) }

      before do
        allow(EntryPair).to receive(:find_by!).and_return(credit_entry_pair_id_double)
        allow(EntryPair).to receive(:remove_credit)
        allow(EntryPair).to receive(:remove_pix_fee)
        allow(EntryPair).to receive(:remove_pix_payment)
      end

      it "reverses the payment by calling the appropriate services" do # rubocop:disable RSpec/MultipleExpectations
        pay_pix.perform_undo
        expect(EntryPair).to have_received(:remove_credit)
        expect(EntryPair).to have_received(:remove_pix_fee)
        expect(EntryPair).to have_received(:remove_pix_payment)
      end
    end

    describe "#call" do
      subject(:operation) { build(:pay_pix) }

      it_behaves_like "an operation call"
    end
  end
end
