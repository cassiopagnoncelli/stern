require "rails_helper"

module Stern
  module Workers
    RSpec.describe Runner, type: :model do
      self.use_transactional_tests = false

      # Silence the worker's info/error logs during tests. Logger.new("/dev/null")
      # is cheap and keeps the spec output clean. Per-test override if you want
      # to inspect log calls (see "error isolation" tests).
      let(:null_logger) { Logger.new("/dev/null") }

      # Ordering note: RSpec runs `after` hooks LIFO, so the LAST-declared
      # `after` block runs FIRST. Runner shutdown has to happen before
      # `Repair.clear` — otherwise the runner's worker threads still hold DB
      # connections and `Repair.clear` times out waiting for a connection.
      before { Repair.clear }
      before { @runners = [] }
      after { Repair.clear }
      after { @runners.each { |r| r.shutdown!(timeout: 5) } }

      def make_runner(**kwargs)
        r = described_class.new(install_signal_handlers: false, logger: null_logger, **kwargs)
        @runners << r
        r
      end

      # Seeds a pending SOP that will fire immediately.
      def seed_sop(merchant_id: 1101, charge_id: nil)
        ScheduledOperation.create!(
          name: "ChargePix",
          params: {
            charge_id: charge_id || SecureRandom.random_number(1 << 30),
            merchant_id: merchant_id,
            customer_id: 2,
            amount: 100,
            currency: "usd"
          },
          after_time: 1.minute.ago,
          status: :pending,
        )
      end

      describe "#initialize" do
        it "accepts defaults" do
          runner = make_runner
          expect(runner.stopping?).to be(false)
          expect(runner.in_flight_count).to eq(0)
        end

        it "raises for concurrency <= 0" do
          expect {
            described_class.new(concurrency: 0, install_signal_handlers: false, logger: null_logger)
          }.to raise_error(ArgumentError, /concurrency must be > 0/)
        end

        it "accepts positive concurrency" do
          runner = make_runner(concurrency: 4)
          expect(runner).to be_a(described_class)
        end
      end

      describe "#run_once" do
        let(:runner) { make_runner }

        it "is a no-op when no SOPs are pending" do
          expect { runner.run_once }.not_to raise_error
        end

        it "picks and processes a ready SOP to :finished" do
          sop = seed_sop

          runner.run_once
          # Thread pool is asynchronous; wait briefly for the in-flight SOP.
          deadline = Time.now + 5
          sleep 0.02 while sop.reload.status != "finished" && Time.now < deadline

          expect(sop.reload.status).to eq("finished")
        end

        it "processes multiple SOPs up to concurrency in a single tick" do
          concurrency = 3
          runner = make_runner(concurrency: concurrency)
          sops = Array.new(concurrency) { seed_sop }

          runner.run_once
          deadline = Time.now + 5
          sleep 0.02 while sops.any? { |s| s.reload.status != "finished" } && Time.now < deadline

          expect(sops.map { |s| s.reload.status }).to all(eq("finished"))
        end

        it "refreshes Prometheus queue-depth gauges" do
          Metrics.reset!
          Metrics.install_subscribers!
          seed_sop
          runner.run_once

          # Gauge for `pending` should be at most the remaining pending count.
          # Since the picker just picked it, the remainder for `pending` is 0.
          deadline = Time.now + 2
          sleep 0.02 while Metrics.sop_count.get(labels: { status: "pending" }) > 0 && Time.now < deadline

          expect(Metrics.sop_count.get(labels: { status: "pending" })).to eq(0)
        end
      end

      describe "janitor cadence" do
        it "runs the janitor on the first tick (last_janitor_at is nil)" do
          runner = make_runner(concurrency: 1)
          allow(ScheduledOperationService).to receive(:clear_picked)
          allow(ScheduledOperationService).to receive(:clear_in_progress)

          runner.run_once

          expect(ScheduledOperationService).to have_received(:clear_picked).once
          expect(ScheduledOperationService).to have_received(:clear_in_progress).once
        end

        it "skips janitor on subsequent ticks within the interval" do
          runner = make_runner(concurrency: 1, janitor_interval: 60.0)
          allow(ScheduledOperationService).to receive(:clear_picked)
          allow(ScheduledOperationService).to receive(:clear_in_progress)

          runner.run_once
          runner.run_once
          runner.run_once

          expect(ScheduledOperationService).to have_received(:clear_picked).once
          expect(ScheduledOperationService).to have_received(:clear_in_progress).once
        end
      end

      describe "error isolation" do
        it "keeps the runner alive when a single SOP raises inside process_sop" do
          sop = seed_sop
          error = StandardError.new("simulated failure outside service rescue")

          # Force process_sop to raise (simulating an unhandled infrastructure
          # error that slipped past the service's own rescue).
          call_count = 0
          allow(ScheduledOperationService).to receive(:process_sop) do
            call_count += 1
            raise error
          end

          captured = []
          logger = Logger.new(StringIO.new).tap do |l|
            l.formatter = ->(_sev, _dt, _progname, msg) { captured << msg.to_s; "" }
          end

          runner = described_class.new(install_signal_handlers: false, logger: logger)
          @runners << runner

          expect { runner.run_once }.not_to raise_error
          # Wait for the pool worker to actually fire.
          deadline = Time.now + 2
          sleep 0.01 while call_count.zero? && Time.now < deadline

          expect(call_count).to be >= 1
          expect(captured.join("\n")).to include("surfaced unhandled error")
          expect(runner.in_flight_count).to eq(0)
        end
      end

      describe "#start with #stop — graceful shutdown" do
        it "runs continuously, stops on #stop, and returns cleanly" do
          runner = make_runner(poll_interval: 0.1)

          thread = Thread.new { runner.start }

          # Let the loop do at least one tick.
          sleep 0.3
          runner.stop

          # Thread should exit within a reasonable bound.
          thread.join(5)
          expect(thread.alive?).to be(false)
          expect(runner.stopping?).to be(true)
        end

        it "processes a SOP that appears mid-run and stops cleanly afterward" do
          runner = make_runner(poll_interval: 0.1)

          thread = Thread.new { runner.start }

          sop = seed_sop
          deadline = Time.now + 5
          sleep 0.05 while sop.reload.status != "finished" && Time.now < deadline
          expect(sop.reload.status).to eq("finished")

          runner.stop
          thread.join(5)
          expect(thread.alive?).to be(false)
        end
      end
    end
  end
end
