require "rails_helper"

module Stern
  RSpec.describe SplitPayment, type: :model do
    let(:payment_id) { 7001 }
    let(:merchant_id) { 1101 }
    let(:partner_id) { 3303 }

    def valid_inputs(**overrides)
      {
        payment_id:,
        merchant_id:,
        amount: 5000,
        currency: "BRL"
      }.merge(overrides)
    end

    describe "validations" do
      it "is valid with the merchant variant" do
        expect(described_class.new(**valid_inputs)).to be_valid
      end

      it "is valid with the partner variant" do
        op = described_class.new(**valid_inputs(merchant_id: nil, partner_id: partner_id))
        expect(op).to be_valid
      end

      it "rejects when neither merchant_id nor partner_id is set" do
        op = described_class.new(**valid_inputs(merchant_id: nil))
        expect(op).not_to be_valid
        expect(op.errors[:base].join).to match(/exactly one of merchant_id, partner_id/)
      end

      it "rejects when both merchant_id and partner_id are set" do
        op = described_class.new(**valid_inputs(partner_id: partner_id))
        expect(op).not_to be_valid
        expect(op.errors[:base].join).to match(/exactly one of/)
      end

      it "requires payment_id" do
        op = described_class.new(**valid_inputs(payment_id: nil))
        expect(op).not_to be_valid
        expect(op.errors[:payment_id]).to be_present
      end

      it "rejects a non-positive payment_id" do
        expect(described_class.new(**valid_inputs(payment_id: 0))).not_to be_valid
      end

      it "rejects a non-integer payment_id" do
        expect(described_class.new(**valid_inputs(payment_id: 1.5))).not_to be_valid
      end

      it "rejects a non-positive merchant_id" do
        expect(described_class.new(**valid_inputs(merchant_id: 0))).not_to be_valid
      end

      it "requires an amount" do
        expect(described_class.new(**valid_inputs(amount: nil))).not_to be_valid
      end

      it "rejects a zero amount" do
        op = described_class.new(**valid_inputs(amount: 0))
        expect(op).not_to be_valid
        expect(op.errors[:amount]).to be_present
      end

      it "rejects a non-integer amount" do
        expect(described_class.new(**valid_inputs(amount: 1.5))).not_to be_valid
      end

      it "treats an unknown currency as invalid" do
        op = described_class.new(**valid_inputs(currency: "ZZZ"))
        expect(op).not_to be_valid
        expect(op.errors[:currency]).to include(/not a recognized currency/)
      end
    end

    describe "#target_tuples" do
      it "merchant: pins payment_id on the payment book, merchant_id on merchant_pending" do
        op = described_class.new(**valid_inputs)
        expect(op.target_tuples).to eq([
          [ "payment", payment_id, "BRL" ],
          [ "merchant_pending", merchant_id, "BRL" ]
        ])
      end

      it "partner: pins payment_id on the payment book, partner_id on partner_pending" do
        op = described_class.new(**valid_inputs(merchant_id: nil, partner_id: partner_id))
        expect(op.target_tuples).to eq([
          [ "payment", payment_id, "BRL" ],
          [ "partner_pending", partner_id, "BRL" ]
        ])
      end

      it "two splits of the same payment to different merchants serialize on (payment, payment_id)" do
        op_a = described_class.new(**valid_inputs)
        op_b = described_class.new(**valid_inputs(merchant_id: merchant_id + 1))
        shared = op_a.target_tuples & op_b.target_tuples
        expect(shared).to eq([ [ "payment", payment_id, "BRL" ] ])
      end
    end

    describe "#call" do
      before { Repair.clear }

      it "records an Operation row with normalized currency" do
        described_class.new(**valid_inputs).call
        expect(Operation.last).to have_attributes(
          name: "SplitPayment",
          params: hash_including("currency" => ::Stern.cur("BRL")),
        )
      end

      it "writes one entry pair (split_payment_merchant) keyed by payment_id" do
        described_class.new(**valid_inputs).call
        expect(EntryPair.last).to have_attributes(
          code: "split_payment_merchant",
          uid: payment_id,
          amount: 5000,
          currency: ::Stern.cur("BRL"),
        )
      end

      it "debits payment and credits merchant_pending at gid=merchant_id" do
        described_class.new(**valid_inputs).call
        expect(::Stern.balance(merchant_id, :payment, :BRL)).to eq(-5000)
        expect(::Stern.balance(merchant_id, :merchant_pending, :BRL)).to eq(5000)
      end

      it "writes split_payment_partner for the partner variant" do
        described_class.new(**valid_inputs(merchant_id: nil, partner_id: partner_id)).call
        expect(EntryPair.last.code).to eq("split_payment_partner")
      end

      it "stamps every entry with the operation's currency" do
        described_class.new(**valid_inputs).call
        currencies = Entry.where(entry_pair_id: EntryPair.last.id).pluck(:currency).uniq
        expect(currencies).to eq([ ::Stern.cur("BRL") ])
      end

      it "allows the same payment_id across two currencies" do
        described_class.new(**valid_inputs(currency: "BRL")).call
        expect {
          described_class.new(**valid_inputs(currency: "USD")).call
        }.to change(EntryPair, :count).by(1)
      end

      it "allows two splits on the same payment_id (different merchants)" do
        described_class.new(**valid_inputs).call
        expect {
          described_class.new(**valid_inputs(merchant_id: merchant_id + 1)).call
        }.to change(EntryPair, :count).by(1)
      end
    end
  end
end
