# frozen_string_literal: true

require "concurrent"

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
      NOTIFY_CHANNEL = "stern_sop_pending"

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
          run_once
          # Wait up to poll_interval OR until NOTIFY wakes us. Either way,
          # the next iteration runs a full tick.
          wait_with_notify(@poll_interval)
        end

        @logger.info(log_prefix + "stopping; waiting for #{@in_flight.value} in-flight SOP(s)")
        wait_for_in_flight(SHUTDOWN_TIMEOUT)
        @listen_thread&.join(5)
        @logger.info(log_prefix + "stopped")
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
        end
      end

      def maybe_run_janitor
        now = Time.now.utc
        return if @last_janitor_at && (now - @last_janitor_at) < @janitor_interval

        ::Stern::ScheduledOperationService.clear_picked
        ::Stern::ScheduledOperationService.clear_in_progress
        @last_janitor_at = now
      rescue StandardError => e
        @logger.error(log_prefix + "janitor error: #{e.class}: #{e.message}")
      end

      def refresh_gauges
        ::Stern::Metrics.refresh_queue_gauges!
      rescue StandardError => e
        @logger.error(log_prefix + "metrics error: #{e.class}: #{e.message}")
      end

      def install_signal_handlers
        %w[TERM INT].each { |sig| Signal.trap(sig) { stop } }
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
      def wait_with_notify(seconds)
        @wake_event.reset
        deadline = Time.now + seconds
        until stopping? || @wake_event.set? || Time.now >= deadline
          @wake_event.wait([ deadline - Time.now, 0.1 ].min)
        end
      end

      # Dedicated thread holding one connection, LISTENing on NOTIFY_CHANNEL.
      # On each notify — or on timeout — it sets @wake_event so the main
      # loop can iterate. The with_connection block keeps the connection
      # checked out for the lifetime of the thread; UNLISTEN runs on exit.
      def start_listen_thread
        @listen_thread = Thread.new do
          ::Stern::ApplicationRecord.connection_pool.with_connection do |conn|
            raw = conn.raw_connection
            raw.async_exec("LISTEN #{NOTIFY_CHANNEL}")
            begin
              until stopping?
                # Block up to 1s. Returns nil on timeout; [channel, pid, payload] on notify.
                notify = raw.wait_for_notify(1.0)
                @wake_event.set if notify
              end
            ensure
              raw.async_exec("UNLISTEN #{NOTIFY_CHANNEL}") rescue nil
            end
          end
        rescue StandardError => e
          @logger.error(log_prefix + "listen thread error: #{e.class}: #{e.message}")
        end
      end

      def wait_for_in_flight(timeout)
        deadline = Time.now + timeout
        sleep 0.05 while @in_flight.value.positive? && Time.now < deadline
        pool.shutdown
        pool.wait_for_termination(timeout)
      end

      def log_prefix
        "[Stern::Workers::Runner] "
      end
    end
  end
end
