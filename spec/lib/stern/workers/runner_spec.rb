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

      describe "LISTEN/NOTIFY low-latency pickup" do
        # These tests prove that a freshly-inserted pending SOP is picked up
        # in milliseconds even when poll_interval is much longer — the
        # stern_sop_notify_trigger fires NOTIFY, the runner's LISTEN thread
        # wakes the main loop, and the next tick picks the work up.

        # These unit tests run LISTEN on a separate thread with a separate
        # checked-out connection (NOT the test thread's AR connection), then
        # mutate status from the test thread. That mirrors how the Runner's
        # LISTEN thread operates in production and avoids ambiguity about
        # which connection the NOTIFY is delivered to when LISTEN + INSERT
        # share a session.
        # Returns `[channel, pid, payload]` tuple if a notify arrives within
        # `timeout`, else nil. Uses the block form of `wait_for_notify` because
        # without a block pg returns just the channel String.
        def listen_once(timeout: 2.0)
          notification = Concurrent::MVar.new
          listener_ready = Concurrent::Event.new
          thread = Thread.new do
            ::Stern::ApplicationRecord.connection_pool.with_connection do |conn|
              raw = conn.raw_connection
              raw.async_exec("LISTEN #{described_class::NOTIFY_CHANNEL}")
              listener_ready.set
              begin
                tuple = nil
                raw.wait_for_notify(timeout) { |channel, pid, payload| tuple = [ channel, pid, payload ] }
                notification.put(tuple)
              ensure
                raw.async_exec("UNLISTEN #{described_class::NOTIFY_CHANNEL}") rescue nil
              end
            end
          end
          listener_ready.wait(2.0)
          yield
          thread.join(timeout + 1)
          notification.take
        end

        it "fires a NOTIFY on insert of a pending SOP" do
          notify = listen_once { seed_sop }
          expect(notify).not_to be_nil
          channel, _pid, payload = notify
          expect(channel).to eq(described_class::NOTIFY_CHANNEL)
          expect(payload).to match(/\A\d+\z/)
        end

        it "fires a NOTIFY when a SOP transitions back to pending after a retry" do
          sop = ScheduledOperation.create!(
            name: "ChargePix",
            params: { charge_id: 1, merchant_id: 1101, customer_id: 2, amount: 100, currency: "usd" },
            after_time: 1.minute.ago,
            status: :picked,
          )

          notify = listen_once { sop.update!(status: :pending) }
          expect(notify).not_to be_nil
          _channel, _pid, payload = notify
          expect(payload).to eq(sop.id.to_s)
        end

        it "does NOT fire a NOTIFY on transitions to non-pending statuses" do
          sop = ScheduledOperation.create!(
            name: "ChargePix",
            params: { charge_id: 1, merchant_id: 1101, customer_id: 2, amount: 100, currency: "usd" },
            after_time: 1.minute.ago,
            status: :pending,
          )

          # Use a tight timeout since we expect NOT to receive anything.
          notify = listen_once(timeout: 0.5) { sop.update!(status: :picked) }
          expect(notify).to be_nil
        end

        it "wakes the runner loop from NOTIFY and picks up a fresh SOP in ms, not the full poll interval" do
          # 30-second poll means if LISTEN/NOTIFY doesn't work, this test
          # would wait half a minute. Instead we seed a SOP and expect it
          # finished within 5s.
          runner = make_runner(poll_interval: 30.0, janitor_interval: 300.0)
          thread = Thread.new { runner.start }

          # Give the main loop a moment to enter its first wait_with_notify.
          sleep 0.2

          sop = seed_sop
          deadline = Time.now + 5
          sleep 0.02 while sop.reload.status != "finished" && Time.now < deadline

          expect(sop.reload.status).to eq("finished")
          expect(Time.now - deadline + 5).to be < 5  # finished well before deadline

          runner.stop
          thread.join(5)
        end

        # Regression guard for the reset-race bug surfaced in the audit:
        # if @wake_event.reset had stayed inside `wait_with_notify`, a NOTIFY
        # set during `run_once` would be cleared before the wait observed it.
        # Here we simulate that ordering by setting the event during the
        # pick and asserting the subsequent wait returns immediately.
        it "does not lose a NOTIFY that arrives during run_once" do
          runner = make_runner(poll_interval: 60.0, janitor_interval: 300.0)

          # Simulate: listen thread sets @wake_event during `run_once`.
          # Under the fix (reset BEFORE run_once), the set survives and
          # `wait_with_notify` returns immediately.
          wake_event = runner.instance_variable_get(:@wake_event)
          allow(ScheduledOperationService).to receive(:enqueue_list) do
            wake_event.set
            []
          end

          thread = Thread.new { runner.start }
          sleep 0.1
          started_at = Time.now
          sleep 0.3 # should NOT have been blocked past its wait — if waits the full 60s, test hangs
          # Prove the loop ticked multiple times despite poll_interval=60s.
          expect(ScheduledOperationService).to have_received(:enqueue_list).at_least(2).times
          expect(Time.now - started_at).to be < 1

          runner.stop
          thread.join(5)
        end

        it "can be opted out of via listen_for_notifications: false" do
          runner = make_runner(
            poll_interval: 0.1,
            janitor_interval: 300.0,
            listen_for_notifications: false,
          )
          thread = Thread.new { runner.start }

          sop = seed_sop
          # With no LISTEN but very short poll_interval, pickup is still fast via polling.
          deadline = Time.now + 5
          sleep 0.02 while sop.reload.status != "finished" && Time.now < deadline

          expect(sop.reload.status).to eq("finished")

          runner.stop
          thread.join(5)
        end
      end

      describe "listen-thread resilience" do
        it "reconnects after a transient error and keeps delivering notifications" do
          runner = make_runner(poll_interval: 60.0, janitor_interval: 300.0)

          # Force listen_loop to raise on the first attempt, then succeed
          # subsequently. The backoff loop in start_listen_thread should
          # log, sleep, and retry.
          attempts = Concurrent::AtomicFixnum.new(0)
          allow(runner).to receive(:listen_loop).and_wrap_original do |original, *args|
            n = attempts.increment
            raise PG::ConnectionBad, "simulated blip" if n == 1

            original.call(*args)
          end

          thread = Thread.new { runner.start }
          # Wait for the first failure + retry to land, then the real
          # listen_loop to be running.
          deadline = Time.now + 5
          sleep 0.05 while attempts.value < 2 && Time.now < deadline
          expect(attempts.value).to be >= 2

          # Now fire a real NOTIFY. The reconnected listen thread should
          # wake the main loop and trigger a pick.
          sop = seed_sop
          deadline = Time.now + 5
          sleep 0.05 while sop.reload.status != "finished" && Time.now < deadline

          expect(sop.reload.status).to eq("finished")

          runner.stop
          thread.join(5)
        end
      end

      describe "bulk-update NOTIFY fanout" do
        # Row-level trigger: update_all touching N rows should fire N notifies.
        it "fires one NOTIFY per row on update_all(status: :pending)" do
          # Pre-seed 3 picked SOPs.
          sops = 3.times.map do
            ScheduledOperation.create!(
              name: "ChargePix",
              params: { charge_id: SecureRandom.random_number(1 << 30), merchant_id: 1,
                       customer_id: 2, amount: 100, currency: "usd" },
              after_time: 1.minute.ago, status: :picked,
            )
          end

          payloads = Queue.new
          listener_ready = Concurrent::Event.new
          thread = Thread.new do
            ::Stern::ApplicationRecord.connection_pool.with_connection do |conn|
              raw = conn.raw_connection
              raw.async_exec("LISTEN #{described_class::NOTIFY_CHANNEL}")
              listener_ready.set
              begin
                3.times do
                  raw.wait_for_notify(2.0) { |_c, _p, payload| payloads << payload }
                end
              ensure
                raw.async_exec("UNLISTEN #{described_class::NOTIFY_CHANNEL}") rescue nil
              end
            end
          end
          listener_ready.wait(2.0)

          ScheduledOperation.where(id: sops.map(&:id)).update_all(status: :pending)
          thread.join(5)

          collected = []
          collected << payloads.pop until payloads.empty?
          expect(collected.size).to eq(3)
          expect(collected.map(&:to_i).sort).to eq(sops.map(&:id).sort)
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
