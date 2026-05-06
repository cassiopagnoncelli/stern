require "rails_helper"

module Stern
  RSpec.describe ChargePaymentFee, type: :model do
    let(:merchant_id) { 1101 }
    let(:customer_id) { 2202 }
    let(:partner_id) { 3303 }
    let(:payment_id) { 7001 }

    def valid_inputs(**overrides)
      {
        merchant_id:,
        payment_id:,
        payment_method: "pix",
        amount: 100,
        currency: "BRL"
      }.merge(overrides)
    end

    describe "validations" do
      it "is valid with the merchant variant" do
        expect(described_class.new(**valid_inputs)).to be_valid
      end

      it "is valid with the customer variant" do
        op = described_class.new(**valid_inputs(merchant_id: nil, customer_id: customer_id))
        expect(op).to be_valid
      end

      it "is valid with the partner variant" do
        op = described_class.new(**valid_inputs(merchant_id: nil, partner_id: partner_id))
        expect(op).to be_valid
      end

      it "rejects when no stakeholder is set" do
        op = described_class.new(**valid_inputs(merchant_id: nil))
        expect(op).not_to be_valid
        expect(op.errors[:base].join).to match(/exactly one of merchant_id, customer_id, partner_id/)
      end

      it "rejects when more than one stakeholder is set" do
        op = described_class.new(**valid_inputs(customer_id: customer_id))
        expect(op).not_to be_valid
        expect(op.errors[:base].join).to match(/exactly one of/)
      end

      it "requires payment_id" do
        expect(described_class.new(**valid_inputs(payment_id: nil))).not_to be_valid
      end

      it "rejects payment_method outside the known set" do
        expect(described_class.new(**valid_inputs(payment_method: "wat"))).not_to be_valid
      end

      it "rejects a zero amount" do
        expect(described_class.new(**valid_inputs(amount: 0))).not_to be_valid
      end

      it "treats an unknown currency as invalid" do
        op = described_class.new(**valid_inputs(currency: "ZZZ"))
        expect(op).not_to be_valid
        expect(op.errors[:currency]).to include(/not a recognized currency/)
      end
    end

    describe "#target_tuples" do
      it "for merchant: locks merchant_available, payment_fee_<method>, and merchant_credit" do
        op = described_class.new(**valid_inputs(payment_method: "pix"))
        expect(op.target_tuples).to eq([
          [ "merchant_available", merchant_id, "BRL" ],
          [ "payment_fee_pix", payment_id, "BRL" ],
          [ "merchant_credit", merchant_id, "BRL" ],
          [ "merchant_available", merchant_id, "BRL" ]
        ])
      end

      it "for customer: locks customer_available, payment_fee_<method>, and customer_credit" do
        op = described_class.new(**valid_inputs(merchant_id: nil, customer_id: customer_id))
        expect(op.target_tuples).to eq([
          [ "customer_available", customer_id, "BRL" ],
          [ "payment_fee_pix", payment_id, "BRL" ],
          [ "customer_credit", customer_id, "BRL" ],
          [ "customer_available", customer_id, "BRL" ]
        ])
      end

      it "for partner: locks partner_available, payment_fee_<method>, and partner_credit" do
        op = described_class.new(**valid_inputs(merchant_id: nil, partner_id: partner_id))
        expect(op.target_tuples).to eq([
          [ "partner_available", partner_id, "BRL" ],
          [ "payment_fee_pix", payment_id, "BRL" ],
          [ "partner_credit", partner_id, "BRL" ],
          [ "partner_available", partner_id, "BRL" ]
        ])
      end
    end

    describe "#call" do
      before { Repair.clear }

      it "records an Operation row with normalized currency" do
        described_class.new(**valid_inputs).call
        expect(Operation.last).to have_attributes(
          name: "ChargePaymentFee",
          params: hash_including("currency" => ::Stern.cur("BRL")),
        )
      end

      it "writes one entry pair (charge_pix_fee_merchant) keyed by merchant_id" do
        described_class.new(**valid_inputs).call
        expect(EntryPair.last).to have_attributes(
          code: "charge_pix_fee_merchant",
          uid: merchant_id,
          amount: 100,
          currency: ::Stern.cur("BRL"),
        )
      end

      it "debits merchant_available and credits payment_fee_<method>, both at gid=payment_id" do
        described_class.new(**valid_inputs).call
        expect(::Stern.balance(payment_id, :merchant_available, :BRL)).to eq(-100)
        expect(::Stern.balance(payment_id, :payment_fee_pix, :BRL)).to eq(100)
      end

      it "stamps every entry with the operation's currency" do
        described_class.new(**valid_inputs).call
        currencies = Entry.where(entry_pair_id: EntryPair.last.id).pluck(:currency).uniq
        expect(currencies).to eq([ ::Stern.cur("BRL") ])
      end

      it "writes the right pair name for the customer variant" do
        described_class.new(**valid_inputs(merchant_id: nil, customer_id: customer_id)).call
        expect(EntryPair.last.code).to eq("charge_pix_fee_customer")
      end

      it "writes the right pair name for the partner variant" do
        described_class.new(**valid_inputs(merchant_id: nil, partner_id: partner_id)).call
        expect(EntryPair.last.code).to eq("charge_pix_fee_partner")
      end

      it "allows two fee charges on the same merchant_id and payment_id" do
        described_class.new(**valid_inputs).call
        expect {
          described_class.new(**valid_inputs(amount: 50)).call
        }.to change(EntryPair, :count).by(1)
      end

      it "allows the same merchant_id across two currencies" do
        described_class.new(**valid_inputs(currency: "BRL")).call
        expect {
          described_class.new(**valid_inputs(currency: "USD")).call
        }.to change(EntryPair, :count).by(1)
      end

      context "with available credit" do
        it "applies partial credit when balance < fee, debiting available by the net" do
          AddCredit.new(merchant_id:, amount: 30, currency: "BRL").call

          expect {
            described_class.new(**valid_inputs(amount: 100)).call
          }.to change(EntryPair, :count).by(2)

          expect(::Stern.balance(merchant_id, :merchant_credit, :BRL)).to eq(0)
          expect(::Stern.balance(merchant_id, :merchant_available, :BRL)).to eq(30)
          expect(::Stern.balance(payment_id, :merchant_available, :BRL)).to eq(-100)
          expect(::Stern.balance(payment_id, :payment_fee_pix, :BRL)).to eq(100)
        end

        it "caps credit at the fee amount when balance > fee" do
          AddCredit.new(merchant_id:, amount: 500, currency: "BRL").call

          described_class.new(**valid_inputs(amount: 100)).call

          expect(::Stern.balance(merchant_id, :merchant_credit, :BRL)).to eq(400)
          expect(::Stern.balance(merchant_id, :merchant_available, :BRL)).to eq(100)
        end

        it "skips credit application when the credit balance is zero" do
          expect {
            described_class.new(**valid_inputs(amount: 100)).call
          }.to change(EntryPair, :count).by(1)

          expect(::Stern.balance(merchant_id, :merchant_credit, :BRL)).to eq(0)
        end

        it "skips credit application for negative amounts (fee reversal)" do
          AddCredit.new(merchant_id:, amount: 30, currency: "BRL").call

          expect {
            described_class.new(**valid_inputs(amount: -50)).call
          }.to change(EntryPair, :count).by(1)

          expect(::Stern.balance(merchant_id, :merchant_credit, :BRL)).to eq(30)
        end

        it "applies customer credit for the customer variant" do
          AddCredit.new(customer_id:, amount: 40, currency: "BRL").call

          described_class.new(**valid_inputs(merchant_id: nil, customer_id:, amount: 100)).call

          expect(::Stern.balance(customer_id, :customer_credit, :BRL)).to eq(0)
          expect(::Stern.balance(customer_id, :customer_available, :BRL)).to eq(40)
          expect(::Stern.balance(payment_id, :customer_available, :BRL)).to eq(-100)
        end

        it "applies partner credit for the partner variant" do
          AddCredit.new(partner_id:, amount: 70, currency: "BRL").call

          described_class.new(**valid_inputs(merchant_id: nil, partner_id:, amount: 100)).call

          expect(::Stern.balance(partner_id, :partner_credit, :BRL)).to eq(0)
          expect(::Stern.balance(partner_id, :partner_available, :BRL)).to eq(70)
          expect(::Stern.balance(payment_id, :partner_available, :BRL)).to eq(-100)
        end

        it "only consumes credit in the operation's currency" do
          AddCredit.new(merchant_id:, amount: 50, currency: "USD").call

          described_class.new(**valid_inputs(amount: 100, currency: "BRL")).call

          expect(::Stern.balance(merchant_id, :merchant_credit, :USD)).to eq(50)
          expect(::Stern.balance(merchant_id, :merchant_credit, :BRL)).to eq(0)
        end
      end
    end
  end
end
