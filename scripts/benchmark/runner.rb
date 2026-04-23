# frozen_string_literal: true

require_relative "metrics"

module Benchmark
  # Drives a scenario across a thread pool for a fixed number of iterations.
  # Splits iterations evenly across threads, hands each its own Metrics bucket,
  # and checks out an AR connection per thread so ops don't contend on one.
  class Runner
    attr_reader :scenario, :opts

    def initialize(scenario, opts)
      @scenario = scenario
      @opts = opts
    end

    def run
      banner
      scenario.setup
      warmup if opts[:warmup].positive?
      metrics, wall = measure(opts[:iterations])
      scenario.teardown
      report(metrics, wall)
      sanity_check
      metrics
    end

    private

    def warmup
      puts "warmup: #{opts[:warmup]} iterations on #{opts[:threads]} threads..."
      measure(opts[:warmup], record: false)
    end

    def measure(iterations, record: true)
      per_thread = divide_iterations(iterations, opts[:threads])
      buckets = Array.new(opts[:threads]) { Metrics.new }

      t0 = monotonic_ns
      threads = per_thread.each_with_index.map do |n, tidx|
        Thread.new do
          ::Stern::ApplicationRecord.connection_pool.with_connection do
            run_thread(tidx, n, buckets[tidx])
          ensure
            ::Stern::ApplicationRecord.connection_pool.release_connection
          end
        end
      end
      threads.each(&:join)
      wall_ns = monotonic_ns - t0

      merged = buckets.reduce(Metrics.new) { |acc, b| acc.merge!(b) }
      record ? [ merged, wall_ns ] : nil
    end

    def run_thread(tidx, n, bucket)
      n.times do |i|
        t = monotonic_ns
        begin
          scenario.run_once(i, tidx)
          bucket.record_ok(monotonic_ns - t)
        rescue => e
          bucket.record_error(e.class, monotonic_ns - t)
        end
      end
    end

    def divide_iterations(total, threads)
      base = total / threads
      rem = total % threads
      Array.new(threads) { |i| base + (i < rem ? 1 : 0) }
    end

    def monotonic_ns
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    end

    def banner
      puts "=" * 72
      puts "stern benchmark — #{scenario.class.name.split("::").last}"
      puts "  threads=#{opts[:threads]} iterations=#{opts[:iterations]} " \
           "warmup=#{opts[:warmup]} merchants=#{opts[:merchants]} " \
           "currency=#{opts[:currency]}"
      puts "=" * 72
    end

    def report(metrics, wall_ns)
      wall_s = wall_ns / 1e9
      tput = metrics.total / wall_s

      puts
      puts "results"
      puts "  wall time     : #{format('%.3f s', wall_s)}"
      puts "  total ops     : #{metrics.total}"
      puts "  ok            : #{metrics.ok_count}"
      puts "  errors        : #{metrics.errors.values.sum}"
      puts "  throughput    : #{format('%.1f ops/s', tput)}"
      puts
      puts "latency (ms)"
      puts "  min           : #{fmt_ms(metrics.min_ns)}"
      puts "  mean          : #{fmt_ms(metrics.mean_ns)}"
      puts "  p50           : #{fmt_ms(metrics.percentile(50))}"
      puts "  p95           : #{fmt_ms(metrics.percentile(95))}"
      puts "  p99           : #{fmt_ms(metrics.percentile(99))}"
      puts "  max           : #{fmt_ms(metrics.max_ns)}"
      return if metrics.errors.empty?

      puts
      puts "errors by class"
      metrics.errors.sort_by { |_, v| -v }.each do |klass, n|
        puts "  #{klass.ljust(32)} #{n}"
      end
    end

    def fmt_ms(ns)
      format("%.3f", ns / 1e6)
    end

    def sanity_check
      ok = ::Stern::Doctor.amount_consistent?
      puts
      puts "ledger sanity : Stern::Doctor.amount_consistent? = #{ok}"
      warn "WARNING: ledger amount sum is nonzero" unless ok
    end
  end
end
