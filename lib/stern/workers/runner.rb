# frozen_string_literal: true

require "concurrent"
require "socket"

module Stern
  module Workers
    # Long-running worker that drives `ScheduledOperationService`:
    #   - polls the pending queue
    #   - dispatches picked SOPs onto a fixed thread pool
    #   - runs the janitor (`clear_picked` / `clear_in_progress`) on a slower cadence
    #   - refreshes Prometheus queue-depth gauges once per tick
    #
    # Start with `Stern::Workers::Runner.new(...).start`, or via the
    # `stern:worker:start` rake task for systemd/Kubernetes-style deployment.
    #
    # Graceful shutdown: on SIGTERM/SIGINT (or an explicit `#stop`), the loop
    # stops picking, waits up to SHUTDOWN_TIMEOUT for in-flight SOPs to finish,
    # then returns. Signal handler installation is opt-out for embedded use.
    class Runner
      DEFAULT_CONCURRENCY = 1
      DEFAULT_POLL_INTERVAL = 5.0
      DEFAULT_JANITOR_INTERVAL = 60.0
      SHUTDOWN_TIMEOUT = 30.0

      # Postgres channel the `stern_sop_notify_trigger` NOTIFYs on when a SOP
      # enters `pending`. Workers LISTEN on this channel to get low-latency
      # pickup without tight polling.
      NOTIFY_CHANNEL = "stern_scheduled_operations_pending"

      def initialize(
        concurrency: DEFAULT_CONCURRENCY,
        poll_interval: DEFAULT_POLL_INTERVAL,
        janitor_interval: DEFAULT_JANITOR_INTERVAL,
        logger: Rails.logger,
        install_signal_handlers: true,
        listen_for_notifications: true
      )
        @concurrency = Integer(concurrency)
        raise ArgumentError, "concurrency must be > 0" if @concurrency <= 0

        @poll_interval = Float(poll_interval)
        @janitor_interval = Float(janitor_interval)
        @logger = logger
        @install_signal_handlers = install_signal_handlers
        @listen_for_notifications = listen_for_notifications
        @stop = Concurrent::AtomicBoolean.new(false)
        @in_flight = Concurrent::AtomicFixnum.new(0)
        @last_janitor_at = nil
        @wake_event = Concurrent::Event.new
        @listen_thread = nil
      end

      # Long-running daemon entry point. Returns only on shutdown.
      def start
        install_signal_handlers if @install_signal_handlers
        start_listen_thread if @listen_for_notifications
        @logger.info(log_prefix + "starting " \
          "concurrency=#{@concurrency} poll=#{@poll_interval}s janitor=#{@janitor_interval}s " \
          "listen=#{@listen_for_notifications}")

        until stopping?
          # Reset BEFORE `run_once`. Any NOTIFY delivered during the pick
          # window (while `run_once` is running) must survive into the
          # subsequent `wait_with_notify` so we short-circuit the sleep.
          # Resetting inside `wait_with_notify` would silently drop any
          # signal the listen thread set between the start of this tick
          # and the wait.
          @wake_event.reset
          run_once
          wait_with_notify(@poll_interval)
        end

        @logger.info(log_prefix + "stopping; waiting for #{@in_flight.value} in-flight SOP(s)")
        wait_for_in_flight(SHUTDOWN_TIMEOUT)
        @listen_thread&.join(5)
        @logger.info(log_prefix + "stopped")
      ensure
        # Restore prior TERM/INT handlers so the Runner doesn't leave a
        # stale closure pointing at a dead instance's `@stop` / `@wake_event`
        # in the host process. No-op when handlers weren't installed.
        restore_signal_handlers if @install_signal_handlers
      end

      # Single tick of the loop — pick, process, janitor (if due), refresh gauges.
      # Public for direct invocation in tests and for one-shot manual runs.
      # Catches every exception so a daemon never dies on a tick-level error.
      def run_once
        process_batch
        maybe_run_janitor
        refresh_gauges
      rescue StandardError => e
        @logger.error(log_prefix + "tick error: #{e.class}: #{e.message}")
      end

      # Signals the loop to stop. In-flight SOPs are allowed to finish.
      # Setting the wake event wakes the main loop immediately if it's
      # currently blocked on `wait_with_notify`.
      def stop
        @stop.make_true
        @wake_event.set
      end

      def stopping?
        @stop.true?
      end

      def in_flight_count
        @in_flight.value
      end

      # Stops the loop and synchronously tears down the thread pool. Bounded
      # wait for in-flight SOPs. Safe to call multiple times. Primarily for
      # tests and graceful shutdown — `start` invokes this internally on exit.
      def shutdown!(timeout: SHUTDOWN_TIMEOUT)
        stop
        wait_for_in_flight(timeout)
      end

      private

      def process_batch
        ids = ::Stern::ScheduledOperationService.enqueue_list(@concurrency)
        return if ids.empty?

        ids.each do |id|
          @in_flight.increment
          begin
            pool.post do
              # `with_connection` releases the AR connection back to the pool
              # when the block exits. Without this, the worker thread would
              # permanently hold a connection per pool slot.
              ::Stern::ApplicationRecord.connection_pool.with_connection do
                ::Stern::ScheduledOperationService.process_sop(id)
              end
            rescue StandardError => e
              # `process_sop` has its own rescue for op-level errors; anything
              # reaching here is a bug or infrastructure failure. Keep the runner
              # alive and log.
              @logger.error(log_prefix + "SOP #{id} surfaced unhandled error: #{e.class}: #{e.message}")
            ensure
              @in_flight.decrement
            end
          rescue StandardError => e
            # `pool.post` itself raised — e.g. `Concurrent::RejectedExecutionError`
            # because the pool has been shut down, or a custom fallback policy
            # rejected the task. The block's `ensure` never runs, so decrement
            # here to keep `@in_flight` balanced. Without this, `shutdown!`
            # spins until timeout on a phantom job.
            @in_flight.decrement
            @logger.error(log_prefix + "failed to dispatch SOP #{id}: #{e.class}: #{e.message}")
          end
        end
      end

      def maybe_run_janitor
        now = Time.now.utc
        return if @last_janitor_at && (now - @last_janitor_at) < @janitor_interval

        ::Stern::ScheduledOperationService.clear_picked
        ::Stern::ScheduledOperationService.clear_in_progress
        @last_janitor_at = now
      rescue StandardError => e
        # Set `@last_janitor_at` on failure too — otherwise a chronically
        # broken janitor retries every poll interval, flooding logs (17k
        # error lines/day at 5s polling). The next scheduled janitor run
        # will retry after the normal interval; the underlying problem
        # needs operator intervention either way.
        @last_janitor_at = now
        @logger.error(log_prefix + "janitor error: #{e.class}: #{e.message}")
      end

      def refresh_gauges
        ::Stern::Metrics.refresh_queue_gauges!
      rescue StandardError => e
        @logger.error(log_prefix + "metrics error: #{e.class}: #{e.message}")
      end

      # Install TERM/INT handlers that signal a graceful stop. Captures the
      # prior handler for each signal so `restore_signal_handlers` can put
      # them back — important for embedded use where the host process
      # installs its own handlers before spinning up a Runner.
      #
      # The trap body forks a short-lived thread rather than calling `stop`
      # directly because `stop` sets a `Concurrent::Event` internally, which
      # acquires a Mutex. Taking a Mutex inside a signal handler can
      # deadlock on MRI if the signal preempts the same mutex acquisition
      # on the main thread. `Thread.new` is the documented-safe escape
      # hatch (see concurrent-ruby / stdlib Monitor patterns).
      def install_signal_handlers
        @previous_signal_handlers = {}
        %w[TERM INT].each do |sig|
          @previous_signal_handlers[sig] = Signal.trap(sig) { Thread.new { stop } }
        end
      end

      # Restore the handlers `install_signal_handlers` replaced. Called
      # from `start`'s ensure so the Runner doesn't leak stale closures
      # into the host process after shutdown. Safe to call when
      # handlers weren't installed (no-op).
      def restore_signal_handlers
        return unless @previous_signal_handlers

        @previous_signal_handlers.each do |sig, prev|
          # `Signal.trap` returns "DEFAULT"/"IGNORE" strings for system
          # defaults and a Proc for Ruby-installed handlers; both round-trip
          # cleanly back through `Signal.trap`.
          Signal.trap(sig, prev || "DEFAULT")
        end
        @previous_signal_handlers = nil
      end

      def pool
        @pool ||= Concurrent::FixedThreadPool.new(@concurrency)
      end

      # Sleep in small slices so SIGTERM / #stop is observed promptly.
      def interruptible_sleep(seconds)
        deadline = Time.now + seconds
        while Time.now < deadline && !stopping?
          sleep [ deadline - Time.now, 0.1 ].min
        end
      end

      # Wait up to `seconds` OR until the LISTEN thread sets @wake_event
      # (indicating a new pending SOP arrived). Returns early so the next
      # loop iteration picks the work up in milliseconds instead of waiting
      # for the full poll interval.
      #
      # Callers MUST reset @wake_event before the pick work this wait pairs
      # with — resetting inside this method would lose signals that arrived
      # during the pick.
      def wait_with_notify(seconds)
        deadline = Time.now + seconds
        until stopping? || @wake_event.set? || Time.now >= deadline
          @wake_event.wait([ deadline - Time.now, 0.1 ].min)
        end
      end

      # Backoff sequence when the listen connection dies: 1s, 2s, 4s, 8s,
      # 16s, 30s (capped). Keeps retrying until `stop` is signalled so a
      # transient DB blip doesn't permanently disable low-latency pickup.
      LISTEN_RETRY_BACKOFF_CAP_SECONDS = 30

      # TCP keepalive params for the LISTEN socket. The listen connection is
      # idle by design (no traffic between NOTIFYs), so a NAT / load balancer /
      # firewall can silently drop the half-open connection without either end
      # noticing. The OS default keepalive idle is ~2h on Linux/macOS, which
      # would leave the runner deaf to NOTIFYs for that long before the next
      # `wait_for_notify` call surfaces the dead socket. With these values the
      # OS detects a dead listen connection within ~60s (30s idle + 3 × 10s
      # probes); the existing reconnect loop in `start_listen_thread` then
      # re-establishes it. Polling at @poll_interval is the safety net during
      # the gap.
      LISTEN_KEEPALIVE_IDLE_SECONDS = 30
      LISTEN_KEEPALIVE_INTERVAL_SECONDS = 10
      LISTEN_KEEPALIVE_COUNT = 3

      # Dedicated thread holding one connection, LISTENing on NOTIFY_CHANNEL.
      # On each notify — or on timeout — it sets @wake_event so the main
      # loop can iterate.
      #
      # Resilience: the listen body is wrapped in a retry loop with capped
      # exponential backoff. Connection errors (PG::ConnectionBad, IOError,
      # PgBouncer eviction, brief network blips) log at error level and
      # reconnect; the runner continues polling during the outage. Only
      # `stop` stops the thread for good.
      def start_listen_thread
        @listen_thread = Thread.new do
          attempt = 0
          until stopping?
            begin
              listen_loop
              attempt = 0
            rescue StandardError => e
              @logger.error("#{log_prefix}listen thread error (attempt #{attempt + 1}): " \
                "#{e.class}: #{e.message}; retrying")
              interruptible_sleep([ 2**attempt, LISTEN_RETRY_BACKOFF_CAP_SECONDS ].min)
              attempt += 1
            end
          end
        end
      end

      # One LISTEN session: acquire a connection, register LISTEN, loop on
      # `wait_for_notify` until `stop` is signalled, UNLISTEN on exit.
      # Raises on connection errors so `start_listen_thread` can reconnect.
      def listen_loop
        ::Stern::ApplicationRecord.connection_pool.with_connection do |conn|
          raw = conn.raw_connection
          raw.async_exec("LISTEN #{NOTIFY_CHANNEL}")
          configure_listen_keepalive(raw)
          begin
            until stopping?
              # Block up to 1s. Returns nil on timeout; channel String on notify.
              notify = raw.wait_for_notify(1.0)
              @wake_event.set if notify
            end
          ensure
            begin
              raw.async_exec("UNLISTEN #{NOTIFY_CHANNEL}") if raw
            rescue PG::Error, IOError
              # Connection already gone; nothing to unlisten.
            end
          end
        end
      end

      # Enable TCP keepalive on the LISTEN connection's socket so a half-open
      # connection (NAT/firewall silently dropped) is detected by the OS in
      # ~60s instead of the OS default ~2h. See LISTEN_KEEPALIVE_* constants
      # for rationale. No-op for Unix-domain sockets (local-only, not subject
      # to NAT). pg's `socket_io` returns a `BasicSocket.for_fd(...)` so
      # `setsockopt` works directly. Failures are logged at warn — they should
      # not take down the listen thread.
      def configure_listen_keepalive(raw)
        io = raw.socket_io
        return unless io && io.local_address.ip?

        io.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true)

        # Linux uses TCP_KEEPIDLE; macOS/BSD use TCP_KEEPALIVE for the same
        # "seconds idle before first probe" knob.
        idle_opt =
          if Socket.const_defined?(:TCP_KEEPIDLE)
            Socket::TCP_KEEPIDLE
          elsif Socket.const_defined?(:TCP_KEEPALIVE)
            Socket::TCP_KEEPALIVE
          end
        io.setsockopt(Socket::IPPROTO_TCP, idle_opt, LISTEN_KEEPALIVE_IDLE_SECONDS) if idle_opt

        if Socket.const_defined?(:TCP_KEEPINTVL)
          io.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPINTVL, LISTEN_KEEPALIVE_INTERVAL_SECONDS)
        end
        if Socket.const_defined?(:TCP_KEEPCNT)
          io.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPCNT, LISTEN_KEEPALIVE_COUNT)
        end
      rescue StandardError => e
        @logger.warn(log_prefix + "could not set TCP keepalive on listen socket: " \
          "#{e.class}: #{e.message}")
      end

      # Wait for in-flight SOPs to drain, then shut the pool down. The whole
      # routine is bounded by a SINGLE `timeout` budget: callers that pass
      # `SHUTDOWN_TIMEOUT` should see return within that bound, not 2×.
      #
      # If the pool fails to terminate gracefully within the remaining
      # budget, force-kill it. A SOP blocked on a hung external call (e.g.
      # HTTP with no timeout) would otherwise hold the process open past
      # the SIGTERM grace period — under k8s that means SIGKILL eventually
      # takes it down, losing the chance to release DB connections cleanly.
      # `pool.kill` interrupts the worker threads; we still want to log the
      # outcome so operators can see what happened.
      def wait_for_in_flight(timeout)
        deadline = Time.now + timeout
        sleep 0.05 while @in_flight.value.positive? && Time.now < deadline

        pool.shutdown
        remaining = [ deadline - Time.now, 0 ].max
        terminated = pool.wait_for_termination(remaining)
        unless terminated
          @logger.error(log_prefix + "pool failed to terminate within #{timeout}s; killing " \
            "(#{@in_flight.value} SOP(s) still in-flight)")
          pool.kill
        end
        terminated
      end

      def log_prefix
        "[Stern::Workers::Runner] "
      end
    end
  end
end
