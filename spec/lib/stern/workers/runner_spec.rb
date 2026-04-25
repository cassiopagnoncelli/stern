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
            payment_id: merchant_id,
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

        # Regression guard: `maybe_run_janitor` used to leave `@last_janitor_at`
        # nil on the rescue path, so a chronically-broken janitor retried on
        # every single poll tick — logs fill, real problems get buried. The
        # fix: set `@last_janitor_at = now` in the rescue branch too, so the
        # next attempt respects the normal interval.
        it "respects the janitor interval even when clear_picked keeps raising" do
          runner = make_runner(concurrency: 1, janitor_interval: 60.0)
          allow(ScheduledOperationService).to receive(:clear_picked)
            .and_raise(StandardError, "db down")
          allow(ScheduledOperationService).to receive(:clear_in_progress)

          # First tick: janitor is due (last_janitor_at is nil) — try and fail.
          # Second and third ticks: well within janitor_interval of the first
          # attempt; must NOT retry.
          3.times { runner.run_once }

          expect(ScheduledOperationService).to have_received(:clear_picked).once
          # clear_in_progress is called AFTER clear_picked in the janitor body,
          # so a raise on clear_picked prevents it from running. That's
          # intentional — fail-fast on the first subsystem error.
          expect(ScheduledOperationService).not_to have_received(:clear_in_progress)
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
            params: { charge_id: 1, payment_id: 1101, customer_id: 2, amount: 100, currency: "usd" },
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
            params: { charge_id: 1, payment_id: 1101, customer_id: 2, amount: 100, currency: "usd" },
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

      describe "listen-socket TCP keepalive" do
        # The LISTEN connection sits idle between NOTIFYs. Without TCP
        # keepalives, a half-open connection (NAT/firewall silently dropped)
        # would only be detected on the next write — potentially hours later
        # given libpq's defaults. configure_listen_keepalive sets SO_KEEPALIVE
        # plus the platform-specific TCP_KEEP* knobs so the OS detects death
        # within ~60s.

        let(:runner) { make_runner }

        it "is a no-op for Unix-domain sockets and does not raise" do
          ApplicationRecord.connection_pool.with_connection do |conn|
            raw = conn.raw_connection
            io = raw.socket_io
            skip "test DB is connected via TCP, not Unix socket" if io.local_address.ip?

            expect { runner.send(:configure_listen_keepalive, raw) }.not_to raise_error
          end
        end

        # The TCP-keepalive code path used to be exercised by an integration
        # test against the real DB connection — but it skipped whenever the
        # test DB sat on a Unix socket (the common local config), leaving the
        # path untested in practice. Replaced by a transport-independent test
        # below that synthesizes a real TCP socket pair and exercises
        # configure_listen_keepalive directly. Same coverage, deterministic
        # on every CI build, no platform/DB-config carve-out.
        context "with a synthetic TCP socket (transport-agnostic)" do
          let!(:tcp_server) { TCPServer.new("127.0.0.1", 0) }
          let!(:tcp_client) { TCPSocket.new(tcp_server.addr[3], tcp_server.addr[1]) }
          let!(:tcp_accepted) { tcp_server.accept }
          let(:fake_raw) { double("PG::Connection", socket_io: tcp_client) }

          after do
            [ tcp_client, tcp_accepted, tcp_server ].each do |s|
              s.close unless s.closed?
            rescue IOError
              # Already closed — fine.
            end
          end

          it "enables SO_KEEPALIVE on the underlying TCP socket" do
            runner.send(:configure_listen_keepalive, fake_raw)
            # Platform quirk: Linux's getsockopt(SO_KEEPALIVE) returns 1 when
            # set; macOS/BSD returns the option-number bit (8). Either way,
            # "keepalive on" means non-zero — that's the contract.
            expect(tcp_client.getsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE).int).not_to eq(0)
          end

          it "sets the platform 'idle seconds before first probe' knob to LISTEN_KEEPALIVE_IDLE_SECONDS" do
            runner.send(:configure_listen_keepalive, fake_raw)

            idle_const =
              if Socket.const_defined?(:TCP_KEEPIDLE)
                Socket::TCP_KEEPIDLE
              elsif Socket.const_defined?(:TCP_KEEPALIVE)
                Socket::TCP_KEEPALIVE
              end
            skip "platform exposes neither TCP_KEEPIDLE nor TCP_KEEPALIVE" unless idle_const

            expect(tcp_client.getsockopt(Socket::IPPROTO_TCP, idle_const).int)
              .to eq(described_class::LISTEN_KEEPALIVE_IDLE_SECONDS)
          end

          it "sets TCP_KEEPINTVL to LISTEN_KEEPALIVE_INTERVAL_SECONDS when the platform supports it" do
            skip "platform does not expose TCP_KEEPINTVL" unless Socket.const_defined?(:TCP_KEEPINTVL)

            runner.send(:configure_listen_keepalive, fake_raw)
            expect(tcp_client.getsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPINTVL).int)
              .to eq(described_class::LISTEN_KEEPALIVE_INTERVAL_SECONDS)
          end

          it "sets TCP_KEEPCNT to LISTEN_KEEPALIVE_COUNT when the platform supports it" do
            skip "platform does not expose TCP_KEEPCNT" unless Socket.const_defined?(:TCP_KEEPCNT)

            runner.send(:configure_listen_keepalive, fake_raw)
            expect(tcp_client.getsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPCNT).int)
              .to eq(described_class::LISTEN_KEEPALIVE_COUNT)
          end

          it "leaves SO_KEEPALIVE off when called against a Unix-domain socket (early-return)" do
            unix_pair = UNIXSocket.pair
            unix_raw = double("PG::Connection (Unix)", socket_io: unix_pair.first)
            runner.send(:configure_listen_keepalive, unix_raw)
            # No assertion on the Unix socket — Unix sockets don't implement
            # SO_KEEPALIVE — the contract is "no raise, no-op". Asserting
            # the absence of side effects on the TCP socket would couple to
            # an unrelated socket; the lack of raise is the contract.
            expect { runner.send(:configure_listen_keepalive, unix_raw) }.not_to raise_error
          ensure
            unix_pair&.each { |s| s.close unless s.closed? }
          end
        end

        it "logs a warning and does not raise when setsockopt fails" do
          warnings = []
          logger = Logger.new(StringIO.new).tap do |l|
            l.formatter = ->(sev, _dt, _progname, msg) { warnings << [ sev, msg.to_s ]; "" }
          end
          warned_runner = described_class.new(install_signal_handlers: false, logger: logger)
          @runners << warned_runner

          fake_io = instance_double(BasicSocket)
          fake_addr = instance_double(Addrinfo, ip?: true)
          allow(fake_io).to receive(:local_address).and_return(fake_addr)
          allow(fake_io).to receive(:setsockopt).and_raise(Errno::ENOPROTOOPT)

          fake_raw = double("PG::Connection", socket_io: fake_io)

          expect { warned_runner.send(:configure_listen_keepalive, fake_raw) }.not_to raise_error
          expect(warnings.map { |s, m| [ s, m ] }.any? { |s, m| s == "WARN" && m.include?("TCP keepalive") })
            .to be(true)
        end

        it "is invoked by listen_loop after LISTEN is registered" do
          # Hook the runner's keepalive method and confirm the listen thread
          # calls it. We do not need to wait for a notify — only that the
          # listen thread reaches the post-LISTEN configuration step.
          called = Concurrent::Event.new
          allow(runner).to receive(:configure_listen_keepalive).and_wrap_original do |orig, raw|
            result = orig.call(raw)
            called.set
            result
          end

          thread = Thread.new { runner.start }
          expect(called.wait(5)).to be(true)

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
              params: { charge_id: SecureRandom.random_number(1 << 30), payment_id: 1,
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

        # v02 trigger guard: an UPDATE that leaves the row already-pending
        # (e.g. `update_all(status: :pending)` over a mix where some rows
        # were already pending) must NOT emit a notify for the unchanged
        # rows. Only true transitions into :pending wake listeners. This
        # prevents the runner from being repeatedly woken for work it
        # already knows about.
        it "does NOT fire NOTIFY for rows whose status was already :pending" do
          already_pending = ScheduledOperation.create!(
            name: "ChargePix",
            params: { charge_id: SecureRandom.random_number(1 << 30), payment_id: 1,
                     customer_id: 2, amount: 100, currency: "usd" },
            after_time: 1.minute.ago, status: :pending,
          )
          transitioning = 2.times.map do
            ScheduledOperation.create!(
              name: "ChargePix",
              params: { charge_id: SecureRandom.random_number(1 << 30), payment_id: 1,
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
                # Drain notifies for ~1.5s. We expect 2 (the picked → pending
                # transitions) and explicitly want to assert no third notify
                # arrives for the already-pending row.
                deadline = Time.now + 1.5
                while Time.now < deadline
                  remaining = [ deadline - Time.now, 0.05 ].max
                  raw.wait_for_notify(remaining) { |_c, _p, payload| payloads << payload }
                end
              ensure
                raw.async_exec("UNLISTEN #{described_class::NOTIFY_CHANNEL}") rescue nil
              end
            end
          end
          listener_ready.wait(2.0)

          ids = [ already_pending.id, *transitioning.map(&:id) ]
          ScheduledOperation.where(id: ids).update_all(status: :pending)
          thread.join(3)

          collected = []
          collected << payloads.pop until payloads.empty?
          expect(collected.map(&:to_i).sort).to eq(transitioning.map(&:id).sort)
          expect(collected.map(&:to_i)).not_to include(already_pending.id)
        end
      end

      # Regression guard: if `pool.post` raises (e.g. the pool was shut
      # down between `@in_flight.increment` and the actual `post` call),
      # the earlier implementation orphaned the counter — the posted
      # block's `ensure` never ran, `@in_flight` stayed positive, and
      # `shutdown!` would spin until SHUTDOWN_TIMEOUT on a phantom job.
      # The fix: outer `begin/rescue` around `pool.post` that decrements
      # on rejection and logs.
      describe "BUG #1 — pool.post rejection does not orphan @in_flight" do
        it "decrements @in_flight when pool.post raises" do
          captured = []
          logger = Logger.new(StringIO.new).tap do |l|
            l.formatter = ->(_sev, _dt, _progname, msg) { captured << msg.to_s; "" }
          end
          runner = described_class.new(install_signal_handlers: false, logger: logger)
          @runners << runner

          # Pre-shut-down pool: `post` raises RejectedExecutionError with
          # the default `:abort` fallback policy. This mirrors the exact
          # shutdown race the bug covered.
          dead_pool = Concurrent::FixedThreadPool.new(1)
          dead_pool.shutdown
          dead_pool.wait_for_termination(1)
          allow(runner).to receive(:pool).and_return(dead_pool)

          seed_sop
          expect { runner.run_once }.not_to raise_error
          expect(runner.in_flight_count).to eq(0)
          expect(captured.join("\n")).to include("failed to dispatch SOP")
        end
      end

      # Regression guard: the earlier `wait_for_in_flight` budgeted
      # `timeout` for the busy-wait loop AND another full `timeout` for
      # `pool.wait_for_termination`, so `shutdown!(timeout: T)` could take
      # up to 2×T. Plus: a wedged SOP would hold the pool open forever
      # since we only called `pool.shutdown` (graceful), never `pool.kill`.
      # Fix: single deadline shared across busy-wait + termination, and
      # `pool.kill` when graceful termination times out.
      describe "RISK #1/#2 — SHUTDOWN_TIMEOUT honored with pool.kill fallback" do
        it "returns within the requested timeout even when a SOP is wedged" do
          captured = []
          logger = Logger.new(StringIO.new).tap do |l|
            l.formatter = ->(_sev, _dt, _progname, msg) { captured << msg.to_s; "" }
          end
          runner = described_class.new(install_signal_handlers: false, logger: logger)
          @runners << runner

          # Simulate a SOP that will never return within the test's patience.
          # 10s is long enough to confidently prove the timeout was the
          # forcing mechanism — if the old double-budget bug were still
          # present, `shutdown!(timeout: 0.5)` would take ≥ 1s; and if
          # `pool.kill` were missing, the process would block on this
          # sleep for its full 10s.
          allow(::Stern::ScheduledOperationService).to receive(:process_sop) do
            sleep 10
          end

          seed_sop
          runner.run_once
          # Wait for the pool worker to actually pick it up and enter sleep.
          deadline = Time.now + 1
          sleep 0.02 while runner.in_flight_count.zero? && Time.now < deadline
          expect(runner.in_flight_count).to eq(1)

          started = Time.now
          runner.shutdown!(timeout: 0.5)
          elapsed = Time.now - started

          # Budget: 0.5s timeout + ~0.2s slack for pool.kill bookkeeping.
          # The old code would take ≥ 1s (two 0.5s budgets back-to-back);
          # without pool.kill, it would take the full 10s sleep.
          expect(elapsed).to be < 1.0
          expect(captured.join("\n")).to include("pool failed to terminate")
        end
      end

      # Documented behavior guard: if `pool.post` raises mid-way through
      # iterating picked ids, earlier SOPs are dispatched and later ones
      # remain `:picked` until the janitor recycles them via
      # `clear_picked`. That's an acceptable shape — the runner doesn't
      # lose work, it just takes longer to reach it — but we want a test
      # so the behavior doesn't silently change.
      describe "partial dispatch when pool.post raises mid-iteration" do
        it "dispatches earlier SOPs, leaves later SOPs :picked, and keeps in_flight balanced" do
          # Seed three SOPs so we have predictable iteration.
          seeded_sops = 3.times.map { seed_sop }

          captured = []
          logger = Logger.new(StringIO.new).tap do |l|
            l.formatter = ->(_sev, _dt, _progname, msg) { captured << msg.to_s; "" }
          end
          runner = described_class.new(install_signal_handlers: false, logger: logger, concurrency: 3)
          @runners << runner

          # Wrap `pool.post` so the 2nd call raises. The 1st and 3rd still
          # dispatch normally, so the test proves that `process_batch` does
          # NOT abort iteration on one rejection — earlier and later ids in
          # the same batch are treated independently. Using `and_wrap_original`
          # on the real pool means shutdown/wait_for_termination/kill called
          # from the `after` hook's `shutdown!` still work unmocked.
          real_pool = runner.send(:pool)
          posts = Concurrent::AtomicFixnum.new(0)
          allow(real_pool).to receive(:post).and_wrap_original do |original, *args, &block|
            n = posts.increment
            raise Concurrent::RejectedExecutionError, "simulated mid-iteration rejection" if n == 2

            original.call(*args, &block)
          end

          runner.run_once
          # Let the two successful dispatches drain.
          deadline = Time.now + 5
          sleep 0.02 while runner.in_flight_count.positive? && Time.now < deadline

          expect(runner.in_flight_count).to eq(0)

          statuses = seeded_sops.map { |s| s.reload.status }
          # Exactly one SOP stays :picked (the one whose dispatch raised);
          # the other two reach :finished (or at least leave :picked).
          expect(statuses.count("picked")).to eq(1)
          expect(statuses.count("finished")).to eq(2)

          expect(captured.join("\n")).to include("failed to dispatch SOP")
        end
      end

      # Embedded-use guard: `start` now captures the prior TERM/INT handlers
      # and restores them in its ensure block, so a Runner inside a host
      # process doesn't leak a closure pointing at a dead instance's
      # `@stop` / `@wake_event` once it exits. If the restoration regresses,
      # a subsequent SIGTERM to the host goes to the dead runner's closure
      # and is effectively ignored.
      describe "signal handler restoration" do
        it "restores prior TERM/INT handlers when start returns" do
          marker = Object.new
          prior_term = ->(_sig) { marker }
          prior_int  = ->(_sig) { marker }

          # Install sentinels so we can verify Signal.trap returns them to us
          # when the Runner tears down.
          old_term = Signal.trap("TERM", prior_term)
          old_int  = Signal.trap("INT",  prior_int)

          begin
            runner = described_class.new(logger: null_logger, install_signal_handlers: true)
            thread = Thread.new { runner.start }
            # Give `start` enough time to install handlers and enter the loop.
            deadline = Time.now + 2
            sleep 0.02 until Time.now >= deadline || thread.status == "sleep"

            runner.stop
            thread.join(5)
            expect(thread.alive?).to be(false)

            # After shutdown, Signal.trap should return OUR prior handler, not
            # the Runner's closure. Trap with "DEFAULT" just to inspect the
            # current handler.
            current_term = Signal.trap("TERM", "DEFAULT")
            current_int  = Signal.trap("INT",  "DEFAULT")
            expect(current_term).to eq(prior_term)
            expect(current_int).to eq(prior_int)
          ensure
            # Restore whatever was in place before this test started, so we
            # leave no residue for later tests.
            Signal.trap("TERM", old_term || "DEFAULT")
            Signal.trap("INT",  old_int  || "DEFAULT")
          end
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
