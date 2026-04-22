#!/usr/bin/env ruby
# frozen_string_literal: true

# Benchmark Stern operations under concurrent load.
#
# Usage:
#   bundle exec ruby scripts/stress/run.rb --op=charge_pix [options]
#
# Options:
#   --op=NAME            scenario name (required; e.g. charge_pix)
#   --threads=N          concurrent worker threads (default: 8)
#   --iterations=N       total ops to run after warmup (default: 2000)
#   --warmup=N           warmup ops (not measured; default: 200)
#   --merchants=N        distinct merchant gids to rotate through (default: 16)
#   --amount=N           per-op amount in cents (default: 1000)
#   --currency=CODE      currency code (default: BRL)
#   --seed=N             randomness seed for merchant id base (default: 1)
#   --no-reset           skip Stern::Repair.clear before the run
#   --list               list available scenarios and exit
#
# Environment:
#   RAILS_ENV            defaults to development
#   STERN_CHART          defaults to general (must match a chart with the op)

require "optparse"

ENV["RAILS_ENV"] ||= "development"

if ENV["RAILS_ENV"] == "production"
  abort "refusing to run stress benchmark in RAILS_ENV=production"
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
  Stress::Scenarios.const_get(const_name)
rescue NameError
  nil
end

def available_scenarios
  Stress::Scenarios.constants
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
Stress::Runner.new(scenario, opts).run
