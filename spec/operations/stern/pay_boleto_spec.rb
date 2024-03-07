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
      subject(:pay_boleto) { build(:pay_boleto, payment_id:, merchant_id:, amount:, fee:) }

      let(:operation_name) { "Payboleto" }
      let(:operation_params) { { payment_id:, merchant_id:, amount:, fee: } }
      let(:payment_id) { 777 }
      let(:merchant_id) { 1101 }
      let(:amount) { 9900 }
      let(:fee) { 100 }

      before do
        allow(pay_boleto).to receive(:lock_tables)
        allow(pay_boleto).to receive(:perform)
        allow(pay_boleto).to receive(:perform_undo)
      end

      it "performs the do operation within a transaction locking tables" do
        pay_boleto.call(direction: :do, transaction: true)
        expect(pay_boleto).to have_received(:perform)
        expect(pay_boleto).to have_received(:lock_tables)
      end

      it "performs the undo operation within a transaction locking tables" do
        pay_boleto.call(direction: :undo, transaction: true)
        expect(pay_boleto).to have_received(:perform_undo)
        expect(pay_boleto).to have_received(:lock_tables)
      end

      it "raises an ArgumentError when an invalid direction is given" do
        expect {
          pay_boleto.call(direction: :invalid)
        }.to raise_error(ArgumentError, "provide `direction` with :do or :undo")
      end

      describe "linked operation" do
        context "when direction is forwards" do
          it "records the operation" do
            expect {
              pay_boleto.call(direction: :do, transaction: true)
            }.to change(Operation, :count).by(1)
          end
        end

        context "when direction is backwards" do
          it "records the operation" do
            expect {
              pay_boleto.call(direction: :undo, transaction: true)
            }.to change(Operation, :count).by(1)
          end
        end
      end
    end

    describe "#display" do
      subject(:pay_boleto) do
        build(:pay_boleto, payment_id: 123, merchant_id: 456, amount: 789, fee: 12)
      end

      it "returns formatted string" do
        expect(pay_boleto.display).to match(described_class.name.gsub("Stern::", ""))
        expect(pay_boleto.display).to match("payment_id=123 merchant_id=456 amount=789 fee=12")
      end
    end
  end
end
