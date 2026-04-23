require "rails_helper"

module Stern
  RSpec.describe RefundPix, type: :model do
    let(:merchant_id) { 1101 }
    let(:customer_id) { 2202 }
    let(:payment_id) { 9001 }

    def valid_inputs(**overrides)
      {
        refund_id: 7001,
        payment_id:,
        merchant_id:,
        customer_id:,
        amount: 9900,
        currency: "BRL"
      }.merge(overrides)
    end

    describe "validations" do
      it "is valid with complete inputs" do
        expect(described_class.new(**valid_inputs)).to be_valid
      end

      it "requires a refund_id" do
        op = described_class.new(**valid_inputs(refund_id: nil))
        expect(op).not_to be_valid
      end

      it "requires a payment_id" do
        op = described_class.new(**valid_inputs(payment_id: nil))
        expect(op).not_to be_valid
      end

      it "requires a merchant_id" do
        op = described_class.new(**valid_inputs(merchant_id: nil))
        expect(op).not_to be_valid
      end

      it "requires a positive amount" do
        op = described_class.new(**valid_inputs(amount: 0))
        expect(op).not_to be_valid
      end

      it "requires a currency" do
        op = described_class.new(**valid_inputs(currency: nil))
        expect(op).not_to be_valid
      end

      it "rejects an unknown currency" do
        expect { described_class.new(**valid_inputs(currency: "ZZZ")) }.to raise_error(UnknownCurrencyError)
      end

      it "rejects a non-positive customer_id" do
        op = described_class.new(**valid_inputs(customer_id: 0))
        expect(op).not_to be_valid
      end

      it "rejects a negative fee" do
        op = described_class.new(**valid_inputs(fee: -1))
        expect(op).not_to be_valid
      end
    end

    describe "#call" do
      before { Repair.clear }

      it "records an Operation row" do
        described_class.new(**valid_inputs).call
        expect(Operation.last).to have_attributes(
          name: "RefundPix",
          params: hash_including("refund_id" => 7001, "payment_id" => payment_id, "currency" => ::Stern.cur("BRL")),
        )
      end

      it "writes two entry pairs (refund + identified customer) with customer_id" do
        expect { described_class.new(**valid_inputs).call }.to change(EntryPair, :count).by(2)
      end

      it "records the refunded amount on pp_refund_merchant_pix keyed by payment_id" do
        described_class.new(**valid_inputs(refund_id: 10, payment_id: 500, amount: 500)).call
        expect(::Stern.balance(500, :pp_refund_merchant_pix, :BRL)).to eq(500)
      end

      it "allows multiple partial refunds to accumulate on the same payment" do
        described_class.new(**valid_inputs(refund_id: 10, amount: 400)).call
        described_class.new(**valid_inputs(refund_id: 11, amount: 600)).call

        expect(::Stern.balance(payment_id, :pp_refund_merchant_pix, :BRL)).to eq(1000)
      end

      it "keeps refund balances independent across distinct payments" do
        described_class.new(**valid_inputs(refund_id: 1, payment_id: 100, amount: 500)).call
        described_class.new(**valid_inputs(refund_id: 2, payment_id: 200, amount: 1500)).call

        expect(::Stern.balance(100, :pp_refund_merchant_pix, :BRL)).to eq(500)
        expect(::Stern.balance(200, :pp_refund_merchant_pix, :BRL)).to eq(1500)
      end

      it "reverses the charge's customer-side effect when paired with a ChargePix" do
        ChargePix.new(
          charge_id: payment_id, merchant_id:, customer_id:, amount: 9900, currency: "BRL"
        ).call

        expect(::Stern.balance(customer_id, :pp_charge_identified_customer, :BRL)).to eq(-9900)
        expect(::Stern.balance(customer_id, :pp_charge_merchant, :BRL)).to eq(9900)

        described_class.new(
          refund_id: 1, payment_id:, merchant_id:, customer_id:, amount: 9900, currency: "BRL"
        ).call

        expect(::Stern.balance(customer_id, :pp_charge_identified_customer, :BRL)).to eq(0)
        expect(::Stern.balance(customer_id, :pp_charge_merchant, :BRL)).to eq(0)
        expect(::Stern.balance(payment_id, :pp_refund_merchant_pix, :BRL)).to eq(9900)
      end

      it "allows a partial refund" do
        ChargePix.new(
          charge_id: payment_id, merchant_id:, customer_id:, amount: 9900, currency: "BRL"
        ).call

        described_class.new(
          refund_id: 1, payment_id:, merchant_id:, customer_id:, amount: 4000, currency: "BRL"
        ).call

        expect(::Stern.balance(customer_id, :pp_charge_identified_customer, :BRL)).to eq(-5900)
        expect(::Stern.balance(customer_id, :pp_charge_merchant, :BRL)).to eq(5900)
        expect(::Stern.balance(payment_id, :pp_refund_merchant_pix, :BRL)).to eq(4000)
      end

      context "without customer_id" do
        it "reverses the unidentified customer side" do
          ChargePix.new(
            charge_id: payment_id, merchant_id:, customer_id: nil, amount: 9900, currency: "BRL"
          ).call

          expect(::Stern.balance(merchant_id, :pp_charge_unidentified_customer, :BRL)).to eq(-9900)
          expect(::Stern.balance(merchant_id, :pp_charge_merchant, :BRL)).to eq(9900)

          described_class.new(
            refund_id: 1, payment_id:, merchant_id:, customer_id: nil, amount: 9900, currency: "BRL"
          ).call

          expect(::Stern.balance(merchant_id, :pp_charge_unidentified_customer, :BRL)).to eq(0)
          expect(::Stern.balance(merchant_id, :pp_charge_merchant, :BRL)).to eq(0)
        end
      end

      context "with a fee" do
        it "writes an additional fee entry pair when fee is positive" do
          expect {
            described_class.new(**valid_inputs(fee: 100)).call
          }.to change(EntryPair, :count).by(3)
        end

        it "records the fee on pp_refund_fee_merchant_pix keyed by payment_id" do
          described_class.new(**valid_inputs(refund_id: 11, payment_id: 321, fee: 100)).call
          expect(::Stern.balance(321, :pp_refund_fee_merchant_pix, :BRL)).to eq(100)
        end

        it "does not write a fee entry pair when fee is zero or nil" do
          expect { described_class.new(**valid_inputs(fee: 0)).call }.to change(EntryPair, :count).by(2)
          expect { described_class.new(**valid_inputs(refund_id: 99)).call }.to change(EntryPair, :count).by(2)
        end
      end

      it "keeps BRL and USD refund balances independent" do
        described_class.new(**valid_inputs(refund_id: 1, amount: 500, currency: "BRL")).call
        described_class.new(**valid_inputs(refund_id: 2, amount: 300, currency: "USD")).call

        expect(::Stern.balance(payment_id, :pp_refund_merchant_pix, :BRL)).to eq(500)
        expect(::Stern.balance(payment_id, :pp_refund_merchant_pix, :USD)).to eq(300)
      end
    end
  end
end
