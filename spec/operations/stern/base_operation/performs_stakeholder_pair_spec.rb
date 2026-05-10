require "rails_helper"

module Stern
  RSpec.describe "BaseOperation.performs_stakeholder_pair" do
    # Each example builds an anonymous subclass and stubs `tuples_for_pair`,
    # `EntryPair.public_send`, and `require_sufficient_balance!` so the macro's
    # generated methods are tested in isolation from the chart.
    def define_op(name: "MacroOp", inputs: %i[merchant_id customer_id partner_id amount currency], &block)
      klass = Class.new(BaseOperation) do
        inputs(*inputs)
      end
      klass.class_exec(&block)
      stub_const("Stern::#{name}", klass)
      klass
    end

    let(:merchant_id) { 1101 }
    let(:customer_id) { 2202 }
    let(:partner_id)  { 3303 }
    let(:payment_id)  { 9001 }
    let(:refund_id)   { 9002 }
    let(:operation_id) { 7777 }

    describe "default settings (stakeholder_for, sub/add = :resolved)" do
      let(:klass) do
        define_op do
          performs_stakeholder_pair "adjust_%{type}_balance"
        end
      end

      it "generates target_tuples that locks (pair, stakeholder, stakeholder)" do
        op = klass.new(merchant_id:, amount: 500, currency: "BRL")
        expect(op).to receive(:tuples_for_pair)
          .with(:adjust_merchant_balance, merchant_id, merchant_id, "BRL")
          .and_return([ :sentinel ])
        expect(op.target_tuples).to eq([ :sentinel ])
      end

      it "generates perform that writes EntryPair.add_<pair>(stk, stk, amount, currency, operation_id:)" do
        op = klass.new(customer_id:, amount: 250, currency: "BRL")
        expect(EntryPair).to receive(:public_send)
          .with(:add_adjust_customer_balance, customer_id, customer_id, 250, "BRL", operation_id: operation_id)
        op.perform(operation_id)
      end

      it "interpolates :type from the resolved stakeholder branch" do
        op = klass.new(partner_id:, amount: 50, currency: "BRL")
        expect(EntryPair).to receive(:public_send)
          .with(:add_adjust_partner_balance, partner_id, partner_id, 50, "BRL", operation_id: operation_id)
        op.perform(operation_id)
      end

      it "does not define runtime_check when requires_balance is omitted" do
        op = klass.new(merchant_id:, amount: 1, currency: "BRL")
        # Inherited no-op runtime_check from BaseOperation; macro must not redefine.
        expect(klass.instance_method(:runtime_check).owner).to eq(BaseOperation)
      end
    end

    describe "using: :funder_for" do
      let(:klass) do
        define_op(inputs: %i[merchant_id partner_id customer_id refund_id amount currency]) do
          performs_stakeholder_pair "reverse_refund_%{type}",
            using: :funder_for,
            sub_gid: :customer_id,
            entry_uid: :refund_id
        end
      end

      it "scans only merchant/partner — customer is not a candidate" do
        op = klass.new(merchant_id:, customer_id:, refund_id:, amount: 100, currency: "BRL")
        expect(op).to receive(:tuples_for_pair)
          .with(:reverse_refund_merchant, customer_id, merchant_id, "BRL")
        op.target_tuples
      end

      it "passes refund_id (entry_uid) to EntryPair.add_*, not the lock sub_gid" do
        op = klass.new(merchant_id:, customer_id:, refund_id:, amount: 100, currency: "BRL")
        expect(EntryPair).to receive(:public_send)
          .with(:add_reverse_refund_merchant, refund_id, merchant_id, 100, "BRL", operation_id: operation_id)
        op.perform(operation_id)
      end
    end

    describe "entry_uid + entry_gid swap (CancelRefund-style)" do
      let(:klass) do
        define_op(inputs: %i[merchant_id partner_id refund_id amount currency]) do
          performs_stakeholder_pair "cancel_refund_%{type}",
            sub_gid: :refund_id,
            add_gid: :resolved,
            entry_uid: :resolved,
            entry_gid: :refund_id
        end
      end

      it "locks (refund_id, stakeholder_id) but writes the entry at (uid: stakeholder_id, gid: refund_id)" do
        op = klass.new(merchant_id:, refund_id:, amount: 1, currency: "BRL")
        expect(op).to receive(:tuples_for_pair)
          .with(:cancel_refund_merchant, refund_id, merchant_id, "BRL")
        op.target_tuples

        expect(EntryPair).to receive(:public_send)
          .with(:add_cancel_refund_merchant, merchant_id, refund_id, 1, "BRL", operation_id: operation_id)
        op.perform(operation_id)
      end
    end

    describe "sub_gid / add_gid override (Symbol input names)" do
      let(:klass) do
        define_op(inputs: %i[merchant_id customer_id partner_id payment_id amount currency]) do
          performs_stakeholder_pair "split_payment_%{type}",
            sub_gid: :payment_id
        end
      end

      it "reads the override slot via public_send" do
        op = klass.new(partner_id:, payment_id:, amount: 1, currency: "BRL")
        expect(op).to receive(:tuples_for_pair)
          .with(:split_payment_partner, payment_id, partner_id, "BRL")
        op.target_tuples
      end
    end

    describe "requires_balance: literal Symbol book" do
      let(:klass) do
        define_op(inputs: %i[merchant_id partner_id refund_id amount currency]) do
          performs_stakeholder_pair "cancel_refund_%{type}",
            add_gid: :refund_id,
            requires_balance: { book: :refund_locked, label: "locked balance", gid: :refund_id }
        end
      end

      it "calls require_sufficient_balance! with the literal book and configured gid" do
        op = klass.new(merchant_id:, refund_id:, amount: 200, currency: "BRL")
        expect(op).to receive(:require_sufficient_balance!).with(
          book_id: :refund_locked,
          gid:     refund_id,
          currency: "BRL",
          amount:   200,
          op_label: kind_of(String),
          balance_label: "locked balance",
        )
        op.runtime_check
      end

      it "uses the class's demodulized_underscored name as op_label" do
        klass = define_op(name: "FancyCancel", inputs: %i[merchant_id partner_id refund_id amount currency]) do
          performs_stakeholder_pair "cancel_refund_%{type}",
            add_gid: :refund_id,
            requires_balance: { book: :refund_locked, label: "locked balance", gid: :refund_id }
        end
        op = klass.new(merchant_id:, refund_id:, amount: 1, currency: "BRL")
        expect(op).to receive(:require_sufficient_balance!).with(hash_including(op_label: "fancy_cancel"))
        op.runtime_check
      end
    end

    describe "requires_balance: templated String book" do
      let(:klass) do
        define_op do
          performs_stakeholder_pair "unlock_%{type}_balance",
            requires_balance: { book: "%{type}_locked", label: "locked balance" }
        end
      end

      it "interpolates %{type} into the book name" do
        op = klass.new(customer_id:, amount: 10, currency: "BRL")
        expect(op).to receive(:require_sufficient_balance!).with(hash_including(
          book_id: :customer_locked,
          gid:     customer_id,
          balance_label: "locked balance",
        ))
        op.runtime_check
      end
    end

    describe "requires_credit_application: true" do
      let(:klass) do
        define_op(inputs: %i[merchant_id customer_id partner_id payment_id amount currency]) do
          performs_stakeholder_pair "charge_some_fee_%{type}",
            add_gid: :payment_id,
            requires_credit_application: true
        end
      end

      it "appends an apply_<type>_credit lock pair on the stakeholder" do
        op = klass.new(merchant_id:, payment_id:, amount: 100, currency: "BRL")
        allow(op).to receive(:tuples_for_pair).and_call_original
        expect(op).to receive(:tuples_for_pair)
          .with(:charge_some_fee_merchant, merchant_id, payment_id, "BRL")
          .and_return([ :fee_lock ])
        expect(op).to receive(:tuples_for_pair)
          .with(:apply_merchant_credit, merchant_id, merchant_id, "BRL")
          .and_return([ :credit_lock ])
        expect(op.target_tuples).to eq([ :fee_lock, :credit_lock ])
      end

      it "calls apply_available_credit before EntryPair.add_<pair>" do
        op = klass.new(partner_id:, payment_id:, amount: 100, currency: "BRL")
        expect(op).to receive(:apply_available_credit)
          .with(partner_id, :partner, operation_id).ordered
        expect(EntryPair).to receive(:public_send)
          .with(:add_charge_some_fee_partner, partner_id, payment_id, 100, "BRL", operation_id: operation_id)
          .ordered
        op.perform(operation_id)
      end
    end

    describe "templates referencing input attrs" do
      let(:klass) do
        define_op(inputs: %i[merchant_id customer_id partner_id payment_id payment_method amount currency]) do
          performs_stakeholder_pair "charge_%{payment_method}_fee_%{type}",
            add_gid: :payment_id
        end
      end

      it "interpolates %{payment_method} from the input value" do
        op = klass.new(merchant_id:, payment_id:, payment_method: "pix", amount: 1, currency: "BRL")
        expect(op).to receive(:tuples_for_pair)
          .with(:charge_pix_fee_merchant, merchant_id, payment_id, "BRL")
        op.target_tuples
      end

      it "uses the interpolated name when writing the entry pair" do
        op = klass.new(customer_id:, payment_id:, payment_method: "credit_card", amount: 1, currency: "BRL")
        expect(EntryPair).to receive(:public_send)
          .with(:add_charge_credit_card_fee_customer, customer_id, payment_id, 1, "BRL", operation_id: operation_id)
        op.perform(operation_id)
      end
    end

    describe "requires_balance: bypass_when" do
      let(:klass) do
        define_op(inputs: %i[merchant_id customer_id partner_id amount currency allow_overdraft]) do
          performs_stakeholder_pair "lock_%{type}_balance",
            requires_balance: { book: "%{type}_available", label: "available balance", bypass_when: :allow_overdraft }
        end
      end

      it "skips the precheck when the named attr is truthy" do
        op = klass.new(merchant_id:, amount: 100, currency: "BRL", allow_overdraft: true)
        expect(op).not_to receive(:require_sufficient_balance!)
        op.runtime_check
      end

      it "runs the precheck when the named attr is falsy" do
        op = klass.new(merchant_id:, amount: 100, currency: "BRL", allow_overdraft: false)
        expect(op).to receive(:require_sufficient_balance!).with(hash_including(book_id: :merchant_available))
        op.runtime_check
      end
    end
  end
end
