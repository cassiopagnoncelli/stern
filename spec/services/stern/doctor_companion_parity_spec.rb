require "rails_helper"

module Stern
  RSpec.describe Doctor, type: :model do
    let(:gid) { 1101 }
    let(:other_gid) { 2202 }
    let(:merchant_book) { ::Stern.chart.book_code(:merchant_available) }
    let(:merchant_companion) { ::Stern.chart.book_code(:merchant_available_0) }
    let(:customer_book) { ::Stern.chart.book_code(:customer_available) }
    let(:customer_companion) { ::Stern.chart.book_code(:customer_available_0) }
    let(:brl) { ::Stern.cur("BRL") }
    let(:usd) { ::Stern.cur("USD") }
    let(:operation) { create(:operation) }

    # Reusable EntryPair to attach synthetic single-sided Entry rows to. The
    # FK to stern_entry_pairs requires a real row; the row's own amount /
    # code is irrelevant to the parity audit (it scans stern_entries only).
    def stub_pair!
      @stub_pair ||= EntryPair.create!(
        code: :merchant_available,
        uid: 99_999,
        amount: 1,
        currency: brl,
        timestamp: 100.years.ago,
        operation_id: operation.id,
      )
    end

    # Single-sided Entry insert that bypasses the EntryPair-level companion
    # write — the engine never produces these in normal operation. Used to
    # manufacture parity breaks for the audit.
    def write_single_entry!(book_id:, gid:, amount:, currency:, timestamp: nil)
      Entry.create!(
        book_id:,
        gid:,
        entry_pair_id: stub_pair!.id,
        amount:,
        currency:,
        timestamp:,
      )
    end

    def seed_balanced_merchant!
      EntryPair.add_merchant_available(1, gid, gid, 100, brl, operation_id: operation.id)
      EntryPair.add_merchant_available(2, gid, gid, 50, brl, operation_id: operation.id)
      EntryPair.add_merchant_available(3, other_gid, other_gid, 25, brl, operation_id: operation.id)
    end

    context "when the ledger is healthy" do
      before { seed_balanced_merchant! }

      it "reports companion_parity_consistent?" do
        expect(described_class).to be_companion_parity_consistent
      end

      it "first_companion_parity_inconsistency returns nil" do
        expect(described_class.first_companion_parity_inconsistency).to be_nil
      end

      it "first_inconsistency returns nil with all invariants intact" do
        expect(described_class.first_inconsistency).to be_nil
      end
    end

    context "with a synthetic single-sided write on one book" do
      before do
        seed_balanced_merchant!
        write_single_entry!(book_id: merchant_book, gid:, amount: 100, currency: brl)
      end

      it "fails companion_parity_consistent?" do
        expect(described_class).not_to be_companion_parity_consistent
      end

      it "localizes the (book, currency) of the broken pair" do
        detail = described_class.first_companion_parity_inconsistency

        expect(detail).to eq(
          book: "merchant_available",
          companion: "merchant_available_0",
          currency: brl,
          sum: 100,
        )
      end
    end

    context "with two cancelling cross-book imbalances" do
      before do
        seed_balanced_merchant!
        # +100 on merchant_available (no matching -100 on its companion)
        write_single_entry!(book_id: merchant_book, gid:, amount: 100, currency: brl)
        # -100 on customer_available (no matching +100 on its companion)
        write_single_entry!(book_id: customer_book, gid:, amount: -100, currency: brl)
      end

      it "amount_consistent? still passes — the gap this audit closes" do
        expect(described_class).to be_amount_consistent
      end

      it "fails companion_parity_consistent?" do
        expect(described_class).not_to be_companion_parity_consistent
      end

      it "scans alphabetically by book name and reports the first broken pair" do
        detail = described_class.first_companion_parity_inconsistency

        expect(detail).to eq(
          book: "customer_available",
          companion: "customer_available_0",
          currency: brl,
          sum: -100,
        )
      end
    end

    context "with a per-currency residual that nets to zero across currencies" do
      before do
        # merchant_available: BRL +50 (no companion), USD -50 (no companion).
        # The two slices cancel when summed across currencies, but each
        # individual currency is broken.
        write_single_entry!(book_id: merchant_book, gid:, amount: 50, currency: brl)
        write_single_entry!(book_id: merchant_book, gid:, amount: -50, currency: usd)
      end

      it "amount_consistent? passes (cross-currency cancellation)" do
        expect(described_class).to be_amount_consistent
      end

      it "fails companion_parity_consistent? per currency" do
        expect(described_class).not_to be_companion_parity_consistent
      end

      it "flags one of the broken (book, currency) slices, not the netted total" do
        detail = described_class.first_companion_parity_inconsistency

        expect(detail[:book]).to eq("merchant_available")
        expect(detail[:companion]).to eq("merchant_available_0")
        # Currencies scan in numeric order; whichever code is smaller appears
        # first. Either way, the residual is the per-currency value (±50),
        # not the netted-across-currencies zero.
        expect(detail[:sum].abs).to eq(50)
        expect([ brl, usd ]).to include(detail[:currency])
      end
    end

    context "first_inconsistency integration" do
      before do
        seed_balanced_merchant!
        # Two cancelling cross-book imbalances: global sum stays 0, no
        # per-tuple cascade is corrupted (create_entry recomputes it), so
        # only the new companion-parity check should fire.
        write_single_entry!(book_id: merchant_book, gid:, amount: 100, currency: brl)
        write_single_entry!(book_id: customer_book, gid:, amount: -100, currency: brl)
      end

      it "surfaces the companion_parity tag when amount + cascade both pass" do
        expect(described_class).to be_amount_consistent

        detail = described_class.first_inconsistency

        expect(detail).to eq(
          kind: :companion_parity,
          book: "customer_available",
          companion: "customer_available_0",
          currency: brl,
          sum: -100,
        )
      end
    end
  end
end
