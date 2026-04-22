require "rails_helper"

module Stern
  RSpec.describe Metrics do
    # Each test resets the registry so assertions are deterministic. The
    # subscribers are idempotent via `@subscribers_installed`, so `reset!` only
    # wipes accumulated metric state, not the subscriptions.
    before { described_class.reset! }
    after { described_class.reset! }

    describe ".registry" do
      it "returns a Prometheus::Client::Registry" do
        expect(described_class.registry).to be_a(Prometheus::Client::Registry)
      end

      it "is memoized" do
        expect(described_class.registry).to equal(described_class.registry)
      end
    end

    describe ".install_subscribers! (idempotency)" do
      it "does not accumulate duplicate subscriptions across repeated calls" do
        described_class.install_subscribers!
        described_class.install_subscribers!
        described_class.install_subscribers!

        # Fire one enqueue event and observe only one increment.
        ActiveSupport::Notifications.instrument("stern.sop.enqueue_list", count: 3)
        expect(described_class.sop_picked_total.get).to eq(3)
      end
    end

    describe "enqueue_list event → sop_picked_total" do
      before { described_class.install_subscribers! }

      it "increments by the picked count" do
        ActiveSupport::Notifications.instrument("stern.sop.enqueue_list", count: 5)
        ActiveSupport::Notifications.instrument("stern.sop.enqueue_list", count: 2)
        expect(described_class.sop_picked_total.get).to eq(7)
      end

      it "tolerates missing count payload (no crash, no change)" do
        ActiveSupport::Notifications.instrument("stern.sop.enqueue_list") { }
        expect(described_class.sop_picked_total.get).to eq(0)
      end
    end

    describe "pickup_lag event → sop_pickup_lag_seconds" do
      before { described_class.install_subscribers! }

      it "records observations against the histogram" do
        ActiveSupport::Notifications.instrument("stern.sop.pickup_lag", lag_seconds: 0.5)
        ActiveSupport::Notifications.instrument("stern.sop.pickup_lag", lag_seconds: 2.0)

        # prometheus-client histograms expose a `get` with accumulated state
        summary = described_class.sop_pickup_lag_seconds.get
        expect(summary["sum"]).to be_within(0.001).of(2.5)
      end
    end

    describe "process_operation event → duration + terminal_total" do
      before { described_class.install_subscribers! }

      it "records duration observations and terminal counter for :finished" do
        ActiveSupport::Notifications.instrument(
          "stern.sop.process_operation", op_name: "TestOp", outcome: :finished
        ) { sleep 0.001 }

        duration = described_class.sop_process_duration_seconds.get(
          labels: { outcome: "finished", op_name: "TestOp" },
        )
        expect(duration["sum"]).to be > 0
        expect(described_class.sop_terminal_total.get(
          labels: { outcome: "finished", op_name: "TestOp" },
        )).to eq(1)
      end

      it "records terminal counter for :argument_error" do
        ActiveSupport::Notifications.instrument(
          "stern.sop.process_operation", op_name: "TestOp", outcome: :argument_error
        ) { }

        expect(described_class.sop_terminal_total.get(
          labels: { outcome: "argument_error", op_name: "TestOp" },
        )).to eq(1)
      end

      it "records terminal counter for :runtime_error" do
        ActiveSupport::Notifications.instrument(
          "stern.sop.process_operation", op_name: "TestOp", outcome: :runtime_error
        ) { }

        expect(described_class.sop_terminal_total.get(
          labels: { outcome: "runtime_error", op_name: "TestOp" },
        )).to eq(1)
      end

      it "records duration but NOT terminal counter for :retried (non-terminal)" do
        ActiveSupport::Notifications.instrument(
          "stern.sop.process_operation", op_name: "TestOp", outcome: :retried
        ) { }

        duration = described_class.sop_process_duration_seconds.get(
          labels: { outcome: "retried", op_name: "TestOp" },
        )
        expect(duration["sum"]).to be >= 0
        expect(described_class.sop_terminal_total.values).to be_empty
      end
    end

    describe ".refresh_queue_gauges!" do
      before { described_class.install_subscribers! }
      before { ScheduledOperation.delete_all }
      after { ScheduledOperation.delete_all }

      it "populates the sop_count gauge from DB status counts" do
        3.times do |i|
          ScheduledOperation.create!(
            name: "ChargePix", params: {},
            after_time: 1.minute.ago, status: :pending,
            status_time: Time.current,
          )
        end
        ScheduledOperation.create!(
          name: "ChargePix", params: {},
          after_time: 1.minute.ago, status: :finished,
          status_time: Time.current,
        )

        described_class.refresh_queue_gauges!

        expect(described_class.sop_count.get(labels: { status: "pending" })).to eq(3)
        expect(described_class.sop_count.get(labels: { status: "finished" })).to eq(1)
        # Every enum value is set (zero for empty buckets).
        expect(described_class.sop_count.get(labels: { status: "picked" })).to eq(0)
      end
    end

    describe "end-to-end integration via ScheduledOperationService" do
      before { described_class.install_subscribers! }
      before { Repair.clear }
      after { Repair.clear }

      it "records enqueue + terminal events when processing a real SOP" do
        sop = ScheduledOperation.create!(
          name: "ChargePix",
          params: { charge_id: 1, merchant_id: 1101, customer_id: 2, amount: 100, currency: "usd" },
          after_time: 1.minute.ago,
          status: :pending,
        )

        picked = ScheduledOperationService.enqueue_list
        expect(picked).to include(sop.id)
        expect(described_class.sop_picked_total.get).to be >= 1

        ScheduledOperationService.process_sop(sop.id)

        terminal = described_class.sop_terminal_total.get(
          labels: { outcome: "finished", op_name: "ChargePix" },
        )
        expect(terminal).to eq(1)
      end
    end
  end
end
