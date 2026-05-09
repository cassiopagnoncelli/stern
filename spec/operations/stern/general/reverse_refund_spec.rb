require "rails_helper"

module Stern
  RSpec.describe ReverseRefund, type: :model do
    let(:merchant_id) { 1101 }
    let(:partner_id) { 3303 }
    let(:customer_id) { 2202 }
    let(:refund_id) { 5151 }

    def valid_inputs(**overrides)
      {
        merchant_id:,
        customer_id:,
        refund_id:,
        amount: 700,
        currency: "BRL"
      }.merge(overrides)
    end

    # Drives the customer to the post-Refund state where they hold `amount`
    # in customer_available, funded by the given stakeholder.
    def settle_refund(funder_kwargs, amount: 700)
      ReintegratePayment.new(refund_id:, amount:, currency: "BRL", **funder_kwargs).call
      Refund.new(customer_id:, refund_id:, amount:, currency: "BRL").call
    end

    describe "validations" do
      it "is valid with the merchant variant" do
        expect(described_class.new(**valid_inputs)).to be_valid
      end

      it "is valid with the partner variant" do
        expect(described_class.new(**valid_inputs(merchant_id: nil, partner_id:))).to be_valid
      end

      it "rejects when no funder is set" do
        op = described_class.new(**valid_inputs(merchant_id: nil))
        expect(op).not_to be_valid
        expect(op.errors[:base].join).to match(/exactly one of merchant_id, partner_id/)
      end

      it "rejects when both funders are set" do
        op = described_class.new(**valid_inputs(partner_id:))
        expect(op).not_to be_valid
      end

      it "rejects a missing customer_id" do
        expect(described_class.new(**valid_inputs(customer_id: nil))).not_to be_valid
      end

      it "rejects a missing refund_id" do
        expect(described_class.new(**valid_inputs(refund_id: nil))).not_to be_valid
      end

      it "rejects a zero amount" do
        op = described_class.new(**valid_inputs(amount: 0))
        expect(op).not_to be_valid
        expect(op.errors[:amount]).to be_present
      end

      it "rejects a negative amount" do
        op = described_class.new(**valid_inputs(amount: -1))
        expect(op).not_to be_valid
        expect(op.errors[:amount]).to be_present
      end

      it "treats an unknown currency as invalid" do
        expect(described_class.new(**valid_inputs(currency: "ZZZ"))).not_to be_valid
      end

      it "defaults allow_overdraft to false" do
        expect(described_class.new(**valid_inputs).allow_overdraft).to eq(false)
      end

      it "accepts allow_overdraft: true" do
        expect(described_class.new(**valid_inputs(allow_overdraft: true))).to be_valid
      end

      it "rejects a non-boolean allow_overdraft" do
        expect(described_class.new(**valid_inputs(allow_overdraft: "yes"))).not_to be_valid
      end
    end

    describe "#target_tuples" do
      it "merchant: locks customer_available@customer_id and merchant_available@merchant_id" do
        op = described_class.new(**valid_inputs)
        expect(op.target_tuples).to eq([
          [ "customer_available", customer_id, "BRL" ],
          [ "merchant_available", merchant_id, "BRL" ]
        ])
      end

      it "partner: locks customer_available@customer_id and partner_available@partner_id" do
        op = described_class.new(**valid_inputs(merchant_id: nil, partner_id:))
        expect(op.target_tuples).to eq([
          [ "customer_available", customer_id, "BRL" ],
          [ "partner_available",  partner_id,  "BRL" ]
        ])
      end
    end

    describe "#call" do
      before { Repair.clear(confirm: true) }

      it "credits merchant_available at gid=merchant_id (funder slot)" do
        settle_refund({ merchant_id: }, amount: 700)

        described_class.new(**valid_inputs(amount: 700)).call

        expect(::Stern.balance(merchant_id, :merchant_available, :BRL)).to eq(700)
      end

      it "credits partner_available at gid=partner_id for partner-funded refunds" do
        settle_refund({ partner_id: }, amount: 700)

        described_class.new(**valid_inputs(merchant_id: nil, partner_id:, amount: 700)).call

        expect(::Stern.balance(partner_id, :partner_available, :BRL)).to eq(700)
      end

      it "writes one entry pair (reverse_refund_merchant) keyed by refund_id" do
        settle_refund({ merchant_id: }, amount: 700)

        described_class.new(**valid_inputs(amount: 700)).call

        expect(EntryPair.last).to have_attributes(
          code: "reverse_refund_merchant",
          uid: refund_id,
          amount: 700,
          currency: ::Stern.cur("BRL"),
        )
      end

      it "writes reverse_refund_partner for the partner variant" do
        settle_refund({ partner_id: }, amount: 700)

        described_class.new(**valid_inputs(merchant_id: nil, partner_id:, amount: 700)).call

        expect(EntryPair.last.code).to eq("reverse_refund_partner")
      end

      it "supports partial reversal: 300 of 700 credits 300 to merchant_available@merchant_id" do
        settle_refund({ merchant_id: }, amount: 700)

        described_class.new(**valid_inputs(amount: 300)).call

        expect(::Stern.balance(merchant_id, :merchant_available, :BRL)).to eq(300)
      end

      it "raises InsufficientFunds when amount exceeds customer_available@customer_id" do
        settle_refund({ merchant_id: }, amount: 100)

        expect {
          described_class.new(**valid_inputs(amount: 500)).call
        }.to raise_error(::Stern::InsufficientFunds, /exceeds available balance/)
      end

      it "does not write any entry pair when the runtime check fails" do
        settle_refund({ merchant_id: }, amount: 100)

        expect {
          begin
            described_class.new(**valid_inputs(amount: 500)).call
          rescue ::Stern::InsufficientFunds
            # expected
          end
        }.not_to change { EntryPair.where(code: "reverse_refund_merchant").count }
      end

      it "with allow_overdraft: true, succeeds even when customer_available@customer_id is short" do
        settle_refund({ merchant_id: }, amount: 100)

        described_class.new(**valid_inputs(amount: 500, allow_overdraft: true)).call

        expect(::Stern.balance(merchant_id, :merchant_available, :BRL)).to eq(500)
      end

      it "is idempotent under the same idem_key with identical params" do
        settle_refund({ merchant_id: }, amount: 700)

        first  = described_class.new(**valid_inputs(amount: 300)).call(idem_key: "rev-refund-#{refund_id}")
        second = described_class.new(**valid_inputs(amount: 300)).call(idem_key: "rev-refund-#{refund_id}")

        expect(second).to eq(first)
        expect(EntryPair.where(code: "reverse_refund_merchant").count).to eq(1)
      end
    end
  end
end
