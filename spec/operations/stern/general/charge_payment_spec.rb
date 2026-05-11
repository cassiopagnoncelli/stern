require "rails_helper"

module Stern
  RSpec.describe ChargePayment, type: :model do
    let(:charge_id) { 9001 }
    let(:payment_id) { 7001 }

    def valid_inputs(**overrides)
      {
        charge_id:,
        payment_id:,
        payment_method: "pix",
        amount: 9900,
        currency: "BRL"
      }.merge(overrides)
    end

    describe "validations" do
      it "is valid with complete inputs" do
        expect(described_class.new(**valid_inputs)).to be_valid
      end

      it "requires charge_id" do
        op = described_class.new(**valid_inputs(charge_id: nil))
        expect(op).not_to be_valid
        expect(op.errors[:charge_id]).to be_present
      end

      it "rejects a non-positive charge_id" do
        expect(described_class.new(**valid_inputs(charge_id: 0))).not_to be_valid
        expect(described_class.new(**valid_inputs(charge_id: -1))).not_to be_valid
      end

      it "rejects a non-integer charge_id" do
        expect(described_class.new(**valid_inputs(charge_id: 1.5))).not_to be_valid
      end

      it "requires payment_id" do
        op = described_class.new(**valid_inputs(payment_id: nil))
        expect(op).not_to be_valid
        expect(op.errors[:payment_id]).to be_present
      end

      it "rejects a non-positive payment_id" do
        expect(described_class.new(**valid_inputs(payment_id: 0))).not_to be_valid
      end

      it "requires payment_method" do
        op = described_class.new(**valid_inputs(payment_method: nil))
        expect(op).not_to be_valid
        expect(op.errors[:payment_method]).to be_present
      end

      it "rejects a payment_method outside the known set" do
        op = described_class.new(**valid_inputs(payment_method: "carrier_pigeon"))
        expect(op).not_to be_valid
        expect(op.errors[:payment_method]).to be_present
      end

      it "accepts every supported payment_method" do
        ChargePayment::PAYMENT_METHODS.each do |m|
          expect(described_class.new(**valid_inputs(payment_method: m))).to be_valid, "expected #{m} valid"
        end
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
        expect(described_class.new(**valid_inputs(amount: 99.5))).not_to be_valid
      end

      it "treats an unknown currency as invalid" do
        op = described_class.new(**valid_inputs(currency: "ZZZ"))
        expect(op).not_to be_valid
        expect(op.errors[:currency]).to include(/not a recognized currency/)
      end

      it "treats a blank currency as invalid" do
        op = described_class.new(**valid_inputs(currency: ""))
        expect(op).not_to be_valid
        expect(op.errors[:currency]).to be_present
      end
    end

    describe "#target_tuples" do
      it "pins charge_id to charged_<method> and payment_id to payment" do
        op = described_class.new(**valid_inputs(payment_method: "pix"))
        expect(op.target_tuples).to eq([
          [ "charged_pix", charge_id, "BRL" ],
          [ "payment", payment_id, "BRL" ]
        ])
      end
    end

    describe "#call" do
      before { Repair.clear(confirm: true) }

      it "records an Operation row with normalized currency" do
        described_class.new(**valid_inputs).call
        expect(Operation.last).to have_attributes(
          name: "ChargePayment",
          params: hash_including("currency" => ::Stern.cur("BRL")),
        )
      end

      it "normalizes the currency string to its integer code by call time" do
        op = described_class.new(**valid_inputs(currency: "brl"))
        op.call
        expect(op.currency).to eq(::Stern.cur("BRL"))
      end

      it "raises ArgumentError on an unknown currency" do
        op = described_class.new(**valid_inputs(currency: "ZZZ"))
        expect { op.call }.to raise_error(ArgumentError, /not a recognized currency/)
      end

      it "writes one entry pair (charge_pix) keyed by charge_id" do
        described_class.new(**valid_inputs).call
        expect(EntryPair.last).to have_attributes(
          code: "charge_pix",
          uid: charge_id,
          amount: 9900,
          currency: ::Stern.cur("BRL"),
        )
      end

      it "credits payment@payment_id and debits charged_pix@charge_id" do
        described_class.new(**valid_inputs).call
        expect(::Stern.balance(payment_id, :payment,     :BRL)).to eq(9900)
        expect(::Stern.balance(charge_id,  :charged_pix, :BRL)).to eq(-9900)
        # Cross-gid leakage is zero.
        expect(::Stern.balance(charge_id,  :payment,     :BRL)).to eq(0)
        expect(::Stern.balance(payment_id, :charged_pix, :BRL)).to eq(0)
      end

      it "stamps every entry with the operation's currency" do
        described_class.new(**valid_inputs).call
        currencies = Entry.where(entry_pair_id: EntryPair.last.id).pluck(:currency).uniq
        expect(currencies).to eq([ ::Stern.cur("BRL") ])
      end

      it "keeps BRL and USD balances independent for the same payment" do
        described_class.new(**valid_inputs(charge_id: 1, currency: "BRL")).call
        described_class.new(**valid_inputs(charge_id: 2, payment_id: payment_id + 1, currency: "USD")).call

        expect(::Stern.balance(payment_id, :payment, :BRL)).to eq(9900)
        expect(::Stern.balance(payment_id + 1, :payment, :USD)).to eq(9900)
      end

      it "allows two charges on the same payment_id" do
        described_class.new(**valid_inputs).call
        expect {
          described_class.new(**valid_inputs(charge_id: charge_id + 1)).call
        }.to change(EntryPair, :count).by(1)
      end

      it "allows the same payment_id across two currencies" do
        described_class.new(**valid_inputs(currency: "BRL")).call
        expect {
          described_class.new(**valid_inputs(charge_id: charge_id + 1, currency: "USD")).call
        }.to change(EntryPair, :count).by(1)
      end
    end
  end
end
