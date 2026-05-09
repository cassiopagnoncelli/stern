require "rails_helper"

module Stern
  RSpec.describe TransferBalance, type: :model do
    let(:from_merchant) { 1101 }
    let(:to_merchant)   { 1102 }
    let(:from_customer) { 2201 }
    let(:to_partner)    { 3303 }

    def valid_inputs(**overrides)
      {
        from_merchant_id: from_merchant,
        to_merchant_id:   to_merchant,
        amount: 300,
        currency: "BRL"
      }.merge(overrides)
    end

    def deposit(stakeholder_kw, amount: 1000)
      Deposit.new(amount:, currency: "BRL", **stakeholder_kw).call
    end

    describe "validations" do
      it "is valid with same-type from/to" do
        expect(described_class.new(**valid_inputs)).to be_valid
      end

      it "is valid with cross-type from/to" do
        op = described_class.new(**valid_inputs(
          from_merchant_id: nil, from_customer_id: from_customer, to_partner_id: to_partner, to_merchant_id: nil
        ))
        expect(op).to be_valid
      end

      it "rejects when no from-stakeholder is set" do
        op = described_class.new(**valid_inputs(from_merchant_id: nil))
        expect(op).not_to be_valid
      end

      it "rejects when no to-stakeholder is set" do
        op = described_class.new(**valid_inputs(to_merchant_id: nil))
        expect(op).not_to be_valid
      end

      it "rejects transferring to self (same type, same id)" do
        op = described_class.new(**valid_inputs(to_merchant_id: from_merchant))
        expect(op).not_to be_valid
        expect(op.errors[:base].join).to match(/cannot transfer to self/)
      end

      it "accepts a nil amount (drain semantics)" do
        expect(described_class.new(**valid_inputs(amount: nil))).to be_valid
      end

      it "rejects a non-positive amount" do
        expect(described_class.new(**valid_inputs(amount: 0))).not_to be_valid
        expect(described_class.new(**valid_inputs(amount: -1))).not_to be_valid
      end

      it "treats an unknown currency as invalid" do
        expect(described_class.new(**valid_inputs(currency: "ZZZ"))).not_to be_valid
      end
    end

    describe "#target_tuples" do
      it "merchant→merchant: locks both available pairs" do
        op = described_class.new(**valid_inputs)
        expect(op.target_tuples).to eq([
          [ "merchant_available_0", from_merchant, "BRL" ],
          [ "merchant_available",   from_merchant, "BRL" ],
          [ "merchant_available_0", to_merchant,   "BRL" ],
          [ "merchant_available",   to_merchant,   "BRL" ]
        ])
      end

      it "customer→partner: locks customer_available and partner_available pairs" do
        op = described_class.new(**valid_inputs(
          from_merchant_id: nil, from_customer_id: from_customer, to_partner_id: to_partner, to_merchant_id: nil
        ))
        expect(op.target_tuples).to eq([
          [ "customer_available_0", from_customer, "BRL" ],
          [ "customer_available",   from_customer, "BRL" ],
          [ "partner_available_0",  to_partner,    "BRL" ],
          [ "partner_available",    to_partner,    "BRL" ]
        ])
      end
    end

    describe "#call" do
      before { Repair.clear }

      it "moves an explicit amount from sender to receiver" do
        deposit({ merchant_id: from_merchant }, amount: 1000)

        described_class.new(**valid_inputs(amount: 300)).call

        expect(::Stern.balance(from_merchant, :merchant_available, :BRL)).to eq(700)
        expect(::Stern.balance(to_merchant,   :merchant_available, :BRL)).to eq(300)
      end

      it "drains the entire available balance when amount is nil" do
        deposit({ merchant_id: from_merchant }, amount: 1000)

        described_class.new(**valid_inputs(amount: nil)).call

        expect(::Stern.balance(from_merchant, :merchant_available, :BRL)).to eq(0)
        expect(::Stern.balance(to_merchant,   :merchant_available, :BRL)).to eq(1000)
      end

      it "rejects when the explicit amount exceeds the available balance" do
        deposit({ merchant_id: from_merchant }, amount: 100)

        expect {
          described_class.new(**valid_inputs(amount: 300)).call
        }.to raise_error(ArgumentError, /larger than available balance/)
      end

      it "rejects when the sender's available balance is zero" do
        expect {
          described_class.new(**valid_inputs(amount: 100)).call
        }.to raise_error(ArgumentError, /no available balance/)
      end

      it "moves money cross-type (customer → partner)" do
        deposit({ customer_id: from_customer }, amount: 500)

        described_class.new(**valid_inputs(
          from_merchant_id: nil, from_customer_id: from_customer, to_partner_id: to_partner, to_merchant_id: nil,
          amount: 250
        )).call

        expect(::Stern.balance(from_customer, :customer_available, :BRL)).to eq(250)
        expect(::Stern.balance(to_partner,    :partner_available,  :BRL)).to eq(250)
      end
    end
  end
end
