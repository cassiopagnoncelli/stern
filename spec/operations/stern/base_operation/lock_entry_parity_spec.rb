# frozen_string_literal: true

require "rails_helper"

module Stern
  # Structural parity between an op's lock-side declaration and its entry
  # writes. Ops that hand-roll both `target_tuples` and `perform` (as opposed
  # to the `performs_stakeholder_pair` macro, which generates both from the
  # same slots) could drift silently: locks taken on one `(sub_gid, add_gid)`
  # while entries are written at another would break the deadlock-prevention
  # invariant documented in
  # `app/operations/stern/base_operation/advisory_locking.rb`.
  #
  # Each example exercises one branch of a direct-caller op with a fixture,
  # captures every `tuples_for_pair(pair, book_sub_gid, book_add_gid,
  # currency)` and `EntryPair.add_<pair>(uid, sub_gid, add_gid, …)` call,
  # pairs them by ordinal (Nth lock paired with Nth write), and asserts both
  # the pair name and `(sub_gid, add_gid)` agree on every position.
  #
  # Macro-driven ops (`performs_stakeholder_pair`) are intentionally omitted —
  # the macro builds the lock side and the write side from the same `sub_gid`
  # / `add_gid` slots, so parity is guaranteed by construction and covered by
  # `performs_stakeholder_pair_spec.rb`.
  RSpec.describe "BaseOperation lock/entry parity", type: :model do
    operation_id = 7777

    # `[label, op_class, attrs, prep_block]`.  Multiple rows per op cover the
    # branches that select a different `(pair_name, sub_gid, add_gid)` triple
    # at runtime (stakeholder type, payment method, refund vs chargeback,
    # amount/fee conditionals).
    cases = [
      [ "Refund",
        Refund,
        { customer_id: 2202, refund_id: 5151, amount: 700, currency: "BRL" } ],

      [ "Chargeback",
        Chargeback,
        { chargeback_id: 6161, amount: 700, currency: "BRL" } ],

      [ "Trade (amount + fee)",
        Trade,
        { investment_id: 8181, amount: 1000, fee: 25, currency: "BRL" } ],

      [ "Trade (amount only, fee zero)",
        Trade,
        { investment_id: 8181, amount: 1000, fee: 0, currency: "BRL" } ],

      [ "Trade (fee only, amount zero)",
        Trade,
        { investment_id: 8181, amount: 0, fee: 25, currency: "BRL" } ],

      [ "Invest",
        Invest,
        { investment_id: 8181, customer_id: 2202, amount: 1000, currency: "BRL" } ],

      [ "Divest",
        Divest,
        { investment_id: 8181, customer_id: 2202, currency: "BRL", allow_overdraft: false },
        ->(op) { op.amount = 500 } ],

      [ "ChargePayment (pix)",
        ChargePayment,
        { charge_id: 4141, payment_id: 9001, payment_method: "pix", amount: 5000, currency: "BRL" } ],

      [ "ChargePayment (credit_card)",
        ChargePayment,
        { charge_id: 4141, payment_id: 9001, payment_method: "credit_card", amount: 5000, currency: "BRL" } ],

      [ "ReintegratePayment (merchant / refund)",
        ReintegratePayment,
        { merchant_id: 1101, refund_id: 5151, amount: 700, currency: "BRL" } ],

      [ "ReintegratePayment (partner / chargeback)",
        ReintegratePayment,
        { partner_id: 3303, chargeback_id: 6161, amount: 700, currency: "BRL" } ],

      [ "TransferBalance (merchant → customer)",
        TransferBalance,
        { from_merchant_id: 1101, to_customer_id: 2202, amount: 500, currency: "BRL", allow_overdraft: true } ],

      [ "TransferBalance (partner → merchant)",
        TransferBalance,
        { from_partner_id: 3303, to_merchant_id: 1102, amount: 500, currency: "BRL", allow_overdraft: true } ],

      [ "TransferBalance (customer → partner)",
        TransferBalance,
        { from_customer_id: 2202, to_partner_id: 3303, amount: 500, currency: "BRL", allow_overdraft: true } ]
    ]

    cases.each do |label, klass, attrs, prep|
      it "#{label}: Nth EntryPair.add_<pair>(uid, sub_gid, add_gid, …) matches Nth tuples_for_pair(pair, sub, add, currency)" do
        op = klass.new(**attrs)
        prep&.call(op)

        # Capture every lock-side request. `tuples_for_pair` is private; we
        # stub it on the instance and return [] so `target_tuples` can still
        # build its result without touching the chart.
        tuple_calls = []
        allow(op).to receive(:tuples_for_pair) do |pair, book_sub_gid, book_add_gid, currency|
          tuple_calls << {
            pair:         pair.to_sym,
            book_sub_gid: book_sub_gid,
            book_add_gid: book_add_gid,
            currency:     currency
          }
          []
        end

        # Capture every write-side call. Stub every chart-derived
        # `add_<pair>` singleton on `EntryPair` so both direct
        # `EntryPair.add_<pair>(...)` calls and `EntryPair.public_send(:add_<pair>, ...)`
        # land in the same recorder.
        add_calls = []
        EntryPair.pair_methods.each do |m|
          allow(EntryPair).to receive(m) do |*args, **_kwargs|
            uid, sub_gid, add_gid, amount, currency = args
            add_calls << {
              pair:     m.to_s.sub(/\Aadd_/, "").to_sym,
              uid:      uid,
              sub_gid:  sub_gid,
              add_gid:  add_gid,
              amount:   amount,
              currency: currency
            }
            nil
          end
        end

        op.target_tuples
        op.perform(operation_id)

        expect(add_calls.size).to eq(tuple_calls.size),
          "expected #{tuple_calls.size} EntryPair.add_<pair> call(s) to mirror " \
          "#{tuple_calls.size} tuples_for_pair call(s), but got #{add_calls.size}. " \
          "Locks: #{tuple_calls.map { |c| c[:pair] }.inspect}, " \
          "Writes: #{add_calls.map { |c| c[:pair] }.inspect}"

        add_calls.zip(tuple_calls).each_with_index do |(write, lock), i|
          expect(write[:pair]).to eq(lock[:pair]),
            "position #{i}: pair name diverged — lock=#{lock[:pair]}, write=#{write[:pair]}"

          expect([ write[:sub_gid], write[:add_gid] ])
            .to eq([ lock[:book_sub_gid], lock[:book_add_gid] ]),
              "position #{i} (#{lock[:pair]}): (sub_gid, add_gid) diverged — " \
              "lock=#{[ lock[:book_sub_gid], lock[:book_add_gid] ].inspect}, " \
              "write=#{[ write[:sub_gid], write[:add_gid] ].inspect}"

          expect(write[:currency]).to eq(lock[:currency]),
            "position #{i} (#{lock[:pair]}): currency diverged — " \
            "lock=#{lock[:currency].inspect}, write=#{write[:currency].inspect}"
        end
      end
    end
  end
end
