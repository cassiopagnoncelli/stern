# frozen_string_literal: true

require "prometheus/client"

module Stern
  # Prometheus metrics for the scheduled-operation pipeline.
  #
  # Events fired via `ActiveSupport::Notifications` inside
  # `Stern::ScheduledOperationService` are translated into Prometheus counters,
  # gauges, and histograms by the subscribers installed via
  # `Stern::Metrics.install_subscribers!` (called from the engine initializer).
  #
  # Host apps integrate by:
  #
  #   1. Calling `Stern::Metrics.refresh_queue_gauges!` before each Prometheus
  #      scrape (or on a timer) to refresh the queue-depth gauges — they're
  #      snapshots of DB state, not event-driven.
  #   2. Mounting their preferred exporter (rack exporter, a `/metrics`
  #      endpoint) against `Stern::Metrics.registry`.
  #
  # Example `/metrics` endpoint in a host app:
  #
  #     # config/routes.rb
  #     get "/metrics", to: "prometheus#index"
  #
  #     # app/controllers/prometheus_controller.rb
  #     class PrometheusController < ActionController::Base
  #       def index
  #         Stern::Metrics.refresh_queue_gauges!
  #         render plain: Prometheus::Client::Formats::Text.marshal(Stern::Metrics.registry)
  #       end
  #     end
  module Metrics
    module_function

    # The single Prometheus registry holding all Stern metrics. Host apps can
    # merge it with their own registry or scrape it directly.
    def registry
      @registry ||= Prometheus::Client::Registry.new
    end

    # Gauge: current row count of `stern_scheduled_operations` by status.
    # Not event-driven — call `refresh_queue_gauges!` to populate.
    def sop_count
      @sop_count ||= registry.gauge(
        :stern_sop_count,
        docstring: "Current number of scheduled operations by status",
        labels: [ :status ],
      )
    end

    # Gauge: current row count of `stern_operation_attempts` by status. Pairs
    # with the worker's auto-prune to surface "is the prune keeping up with
    # insert rate" — sustained growth across ticks means the per-tick
    # `max_batches` cap is too low for the workload.
    # Not event-driven — call `refresh_queue_gauges!` to populate.
    def operation_attempts_count
      @operation_attempts_count ||= registry.gauge(
        :stern_operation_attempts_count,
        docstring: "Current number of operation attempts by status",
        labels: [ :status ],
      )
    end

    # Counter: SOPs picked off the pending queue by `enqueue_list`.
    def sop_picked_total
      @sop_picked_total ||= registry.counter(
        :stern_sop_picked_total,
        docstring: "Total SOPs picked from the pending queue",
      )
    end

    # Counter: SOPs reaching a terminal state. `outcome` is one of
    # `finished` / `argument_error` / `runtime_error`. `retried` is NOT terminal
    # and is not counted here (see `sop_process_duration_seconds` for per-attempt
    # counts via the histogram).
    def sop_terminal_total
      @sop_terminal_total ||= registry.counter(
        :stern_sop_terminal_total,
        docstring: "Total SOPs reaching a terminal state",
        labels: [ :outcome, :op_name ],
      )
    end

    # Histogram: `process_operation` wall-clock duration. One observation per
    # attempt (a retried op produces multiple observations across its
    # lifetime). `outcome` records how the attempt ended.
    def sop_process_duration_seconds
      @sop_process_duration_seconds ||= registry.histogram(
        :stern_sop_process_duration_seconds,
        docstring: "process_operation wall-clock duration per attempt",
        labels: [ :outcome, :op_name ],
        buckets: [ 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30 ],
      )
    end

    # Histogram: time between `after_time` and pick — how late the scheduler
    # was to picking up ready work. Healthy systems keep this near zero.
    def sop_pickup_lag_seconds
      @sop_pickup_lag_seconds ||= registry.histogram(
        :stern_sop_pickup_lag_seconds,
        docstring: "Seconds between after_time and the actual pick timestamp",
        buckets: [ 0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60, 300 ],
      )
    end

    # Refreshes the snapshot gauges that mirror DB state — queue depth and
    # operation-attempt counts. Call this on each Prometheus scrape (or on a
    # timer). Two GROUP BY queries, both cheap relative to anything else the
    # scheduler does. Name kept for backwards compatibility with existing
    # callers (e.g. `Stern::Workers::Runner#refresh_gauges`).
    def refresh_queue_gauges!
      sop_counts = ::Stern::ScheduledOperation.group(:status).count
      ::Stern::ScheduledOperation.statuses.each_key do |status|
        sop_count.set(sop_counts[status] || 0, labels: { status: status })
      end

      attempt_counts = ::Stern::OperationAttempt.group(:status).count
      ::Stern::OperationAttempt.statuses.each_key do |status|
        operation_attempts_count.set(attempt_counts[status] || 0, labels: { status: status })
      end
    end

    # Resets all metric state. Only for test isolation — never call in prod.
    def reset!
      @registry = nil
      @sop_count = nil
      @operation_attempts_count = nil
      @sop_picked_total = nil
      @sop_terminal_total = nil
      @sop_process_duration_seconds = nil
      @sop_pickup_lag_seconds = nil
    end

    # Idempotent — safe to call multiple times across dev-mode reloads.
    def install_subscribers!
      return if @subscribers_installed

      ActiveSupport::Notifications.subscribe("stern.sop.enqueue_list") do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        sop_picked_total.increment(by: event.payload[:count] || 0)
      end

      ActiveSupport::Notifications.subscribe("stern.sop.pickup_lag") do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        sop_pickup_lag_seconds.observe(event.payload[:lag_seconds])
      end

      ActiveSupport::Notifications.subscribe("stern.sop.process_operation") do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        outcome = event.payload[:outcome].to_s
        op_name = event.payload[:op_name].to_s
        sop_process_duration_seconds.observe(
          event.duration / 1000.0,
          labels: { outcome: outcome, op_name: op_name },
        )
        if %w[finished argument_error runtime_error].include?(outcome)
          sop_terminal_total.increment(labels: { outcome: outcome, op_name: op_name })
        end
      end

      @subscribers_installed = true
    end
  end
end
