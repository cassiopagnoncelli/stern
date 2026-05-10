#!/usr/bin/env ruby
# frozen_string_literal: true

# Benchmark Stern operations under concurrent load.
#
# Usage:
#   bundle exec ruby scripts/benchmark/run.rb --op=charge_pix [options]
#
# Options:
#   --op=NAME            scenario name (required; see --list)
#                        e.g. charge_pix, deposit, add_credit,
#                        adjust_balance, transfer_balance
#   --threads=N          concurrent worker threads (default: 8)
#   --iterations=N       total ops to run after warmup (default: 2000)
#   --warmup=N           warmup ops (not measured; default: 200)
#   --merchants=N        distinct merchant gids to rotate through (default: 16)
#   --amount=N           per-op amount in cents (default: 1000)
#   --currency=CODE      currency code (default: BRL)
#   --seed=N             randomness seed for merchant id base (default: 1)
#   --no-reset           skip Stern::Repair.clear before the run
#   --out=PATH           write a JSON metrics artifact to PATH (for CI)
#   --list               list available scenarios and exit
#
# Environment:
#   RAILS_ENV            defaults to development
#   STERN_CHART          defaults to general (must match a chart with the op)

require "json"
require "optparse"

ENV["RAILS_ENV"] ||= "development"

if ENV["RAILS_ENV"] == "production"
  abort "refusing to run benchmark in RAILS_ENV=production"
end

ROOT = File.expand_path("../..", __dir__)
require File.join(ROOT, "spec/dummy/config/environment")

require_relative "runner"

SCENARIOS_DIR = File.expand_path("scenarios", __dir__)

def load_scenarios
  Dir[File.join(SCENARIOS_DIR, "*.rb")].sort.each { |f| require f }
end

def scenario_class(name)
  const_name = name.to_s.split("_").map(&:capitalize).join
  Benchmark::Scenarios.const_get(const_name)
rescue NameError
  nil
end

def available_scenarios
  Benchmark::Scenarios.constants
    .reject { |c| c == :Base }
    .map { |c| c.to_s.gsub(/([a-z])([A-Z])/, '\1_\2').downcase }
    .sort
end

opts = {
  threads: 8,
  iterations: 2000,
  warmup: 200,
  merchants: 16,
  amount: 1000,
  currency: "BRL",
  seed: 1,
  reset: true,
  run_id: Time.now.to_i
}

parser = OptionParser.new do |o|
  o.on("--op=NAME")         { |v| opts[:op] = v }
  o.on("--threads=N",     Integer) { |v| opts[:threads] = v }
  o.on("--iterations=N",  Integer) { |v| opts[:iterations] = v }
  o.on("--warmup=N",      Integer) { |v| opts[:warmup] = v }
  o.on("--merchants=N",   Integer) { |v| opts[:merchants] = v }
  o.on("--amount=N",      Integer) { |v| opts[:amount] = v }
  o.on("--currency=CODE") { |v| opts[:currency] = v }
  o.on("--seed=N",        Integer) { |v| opts[:seed] = v }
  o.on("--no-reset")      { opts[:reset] = false }
  o.on("--out=PATH")      { |v| opts[:out] = v }
  o.on("--list")          { opts[:list] = true }
  o.on("-h", "--help")    { puts File.read(__FILE__).split(/^$/, 2).first; exit 0 }
end
parser.parse!(ARGV)

load_scenarios

if opts[:list]
  puts "available scenarios:"
  available_scenarios.each { |n| puts "  #{n}" }
  exit 0
end

unless opts[:op]
  warn "error: --op is required (see --list)"
  exit 2
end

klass = scenario_class(opts[:op])
unless klass
  warn "error: unknown scenario #{opts[:op].inspect}. available: #{available_scenarios.join(', ')}"
  exit 2
end

pool_size = Stern::ApplicationRecord.connection_pool.size
if opts[:threads] > pool_size
  warn "hint: RAILS_MAX_THREADS=#{pool_size} < --threads=#{opts[:threads]} — " \
       "workers will queue on the AR pool. " \
       "Run with RAILS_MAX_THREADS=#{opts[:threads]} for an unthrottled benchmark."
end

scenario = klass.new(opts)
result = Benchmark::Runner.new(scenario, opts).run
metrics = result.metrics

# JSON artifact: a stable, machine-readable snapshot of this run for cross-run
# comparison in CI (see scripts/benchmark/compare.rb). Schema is versioned so
# the comparator can refuse incompatible inputs rather than silently drift.
if opts[:out]
  wall_s = result.wall_ns / 1e9
  ok = metrics.ok_count
  err = metrics.errors.values.sum
  total = metrics.total

  pg_version =
    begin
      ::Stern::ApplicationRecord.connection.execute("SHOW server_version").first["server_version"]
    rescue StandardError
      nil
    end

  artifact = {
    "schema_version" => 1,
    "scenario" => opts[:op],
    "options" => {
      "threads" => opts[:threads],
      "iterations" => opts[:iterations],
      "warmup" => opts[:warmup],
      "merchants" => opts[:merchants],
      "amount" => opts[:amount],
      "currency" => opts[:currency],
      "seed" => opts[:seed]
    },
    "metrics" => {
      "ops_per_s" => total.positive? ? (total / wall_s) : 0.0,
      "wall_s" => wall_s,
      "ok_count" => ok,
      "error_count" => err,
      "errors" => metrics.errors,
      "latency_ms" => {
        "min" => metrics.min_ns / 1e6,
        "p50" => metrics.percentile(50) / 1e6,
        "mean" => metrics.mean_ns / 1e6,
        "p95" => metrics.percentile(95) / 1e6,
        "p99" => metrics.percentile(99) / 1e6,
        "max" => metrics.max_ns / 1e6
      }
    },
    "env" => {
      "ruby" => RUBY_VERSION,
      "rails" => (defined?(Rails) ? Rails::VERSION::STRING : nil),
      "postgres_server_version" => pg_version,
      "stern_chart" => ENV["STERN_CHART"] || "general",
      "rails_max_threads" => ENV["RAILS_MAX_THREADS"]
    },
    "git" => {
      "sha" => ENV["GITHUB_SHA"],
      "ref" => ENV["GITHUB_REF"],
      "run_id" => ENV["GITHUB_RUN_ID"]
    }
  }

  require "fileutils"
  FileUtils.mkdir_p(File.dirname(opts[:out]))
  File.write(opts[:out], JSON.pretty_generate(artifact) + "\n")
  warn "wrote benchmark artifact to #{opts[:out]}"
end

# Strict mode (STERN_BENCH_STRICT=1): used by CI to surface regressions as a
# non-zero exit. Trips on either:
#   - any operation error during the measured window (transient infra hiccups
#     would also count, but the benchmark is bounded so flakiness should be
#     rare; if it isn't, the ChargePix op itself is unstable and that's worth
#     learning).
#   - a ledger that is not amount-consistent at the end (sum of all entry
#     amounts != 0). This is the strongest invariant Stern offers and any
#     violation signals a real bug, not a flake.
if ENV["STERN_BENCH_STRICT"] == "1"
  errors = metrics.errors.values.sum
  consistent = Stern::Doctor.amount_consistent?
  if errors.positive? || !consistent
    warn "STRICT: errors=#{errors} consistent=#{consistent}"
    exit 1
  end
end
