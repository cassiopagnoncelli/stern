require "rails_helper"

module Stern
  RSpec.describe PayBoleto, type: :model do
    describe "validations" do
      context "when validating for performing" do
        subject(:pay_boleto) { build(:pay_boleto) }

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
        subject(:pay_boleto) { build(:pay_boleto, :undo) }

        it { should validate_presence_of(:payment_id) }
        it { should validate_numericality_of(:payment_id) }

        it "does not validate parameters other than payment_id" do
          expect(pay_boleto).to be_valid(:undo)
        end
      end
    end

    describe "#perform" do
      subject(:perform_payment) { pay_boleto.perform(operation_id) }

      let(:pay_boleto) { build(:pay_boleto) }

      before { pay_boleto.log_operation(:do) }

      context "with valid attributes and operation_id" do
        before { allow(Tx).to receive_messages(add_boleto_fee: true, add_boleto_payment: true) }

        let(:operation_id) { 1 }

        it "calls the external services to process payment" do
          perform_payment
          expect(Tx).to have_received(:add_boleto_fee)
          expect(Tx).to have_received(:add_boleto_payment)
        end
      end

      context "with invalid operation_id" do
        let(:operation_id) { nil }

        it "raises ArgumentError" do
          expect { perform_payment }.to raise_error(ArgumentError)
        end
      end
    end

    describe "#perform_undo" do
      subject(:pay_boleto) { build(:pay_boleto, :undo) }

      let(:credit_tx_id_double) { instance_double(Tx, credit_tx_id: 987) }

      before do
        allow(Tx).to receive(:find_by!).and_return(credit_tx_id_double)
        allow(Tx).to receive(:remove_credit)
        allow(Tx).to receive(:remove_boleto_fee)
        allow(Tx).to receive(:remove_boleto_payment)
      end

      it "reverses the payment by calling the appropriate services" do # rubocop:disable RSpec/MultipleExpectations
        pay_boleto.perform_undo
        expect(Tx).to have_received(:remove_credit)
        expect(Tx).to have_received(:remove_boleto_fee)
        expect(Tx).to have_received(:remove_boleto_payment)
      end
    end

    describe "#call" do
      subject(:operation) { build(:pay_boleto) }

      it_behaves_like "an operation call"
    end
  end
end
