# frozen_string_literal: true

module Stress
  # Per-thread latency + error collector. Results are accumulated thread-locally
  # (no cross-thread locking on the hot path) and merged at the end.
  class Metrics
    attr_reader :latencies_ns, :errors, :ok_count

    def initialize
      @latencies_ns = []
      @errors = Hash.new(0)
      @ok_count = 0
    end

    def record_ok(latency_ns)
      @latencies_ns << latency_ns
      @ok_count += 1
    end

    def record_error(klass, latency_ns)
      @latencies_ns << latency_ns
      @errors[klass.to_s] += 1
    end

    def merge!(other)
      @latencies_ns.concat(other.latencies_ns)
      other.errors.each { |k, v| @errors[k] += v }
      @ok_count += other.ok_count
      self
    end

    def total
      @ok_count + @errors.values.sum
    end

    def percentile(p)
      return 0 if @latencies_ns.empty?

      sorted = @latencies_ns.sort
      idx = ((p / 100.0) * (sorted.size - 1)).round
      sorted[idx]
    end

    def mean_ns
      return 0 if @latencies_ns.empty?

      @latencies_ns.sum.fdiv(@latencies_ns.size)
    end

    def max_ns
      @latencies_ns.max || 0
    end

    def min_ns
      @latencies_ns.min || 0
    end
  end
end
