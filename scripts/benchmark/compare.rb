#!/usr/bin/env ruby
# frozen_string_literal: true

# Compare two benchmark JSON artifacts produced by `run.rb --out=...` and exit
# non-zero when the head run regresses past a configurable threshold.
#
# Usage:
#   bundle exec ruby scripts/benchmark/compare.rb \
#     --baseline=tmp/bench/baseline.json \
#     --head=tmp/bench/head.json
#
# Options:
#   --baseline=PATH      JSON artifact from the reference run (e.g. main)
#   --head=PATH          JSON artifact from the run under test
#   --gate-p95=PCT       fail if head.p95 > baseline.p95 * (1 + PCT/100)
#                        (default: 30; set to "off" to skip)
#   --gate-p99=PCT       fail if head.p99 > baseline.p99 * (1 + PCT/100)
#                        (default: off — p99 over a 200-iter smoke run is too
#                        noisy to gate on; the diff is reported informationally)
#   --gate-throughput=PCT fail if head.ops_per_s < baseline.ops_per_s * (1 - PCT/100)
#                        (default: off)
#
# A markdown summary is appended to $GITHUB_STEP_SUMMARY when set, so the diff
# shows up directly on the PR's checks page.
#
# If the baseline artifact is missing, the script exits 0 with a notice. This
# matches the "first PR after this change merges has nothing to compare to"
# case and the "main hasn't run yet" case — both fine, both expected.

require "json"
require "optparse"

opts = {
  gate_p95: "30",
  gate_p99: "off",
  gate_throughput: "off"
}

parser = OptionParser.new do |o|
  o.on("--baseline=PATH")        { |v| opts[:baseline] = v }
  o.on("--head=PATH")            { |v| opts[:head] = v }
  o.on("--gate-p95=PCT")         { |v| opts[:gate_p95] = v }
  o.on("--gate-p99=PCT")         { |v| opts[:gate_p99] = v }
  o.on("--gate-throughput=PCT")  { |v| opts[:gate_throughput] = v }
  o.on("-h", "--help") do
    puts File.read(__FILE__).split(/^$/, 2).first
    exit 0
  end
end
parser.parse!(ARGV)

unless opts[:head]
  warn "error: --head=PATH is required"
  exit 2
end

unless File.exist?(opts[:head])
  warn "error: head artifact not found at #{opts[:head]}"
  exit 2
end

if opts[:baseline].nil? || !File.exist?(opts[:baseline])
  warn "no baseline at #{opts[:baseline].inspect}; skipping comparison"
  exit 0
end

baseline = JSON.parse(File.read(opts[:baseline]))
head     = JSON.parse(File.read(opts[:head]))

if baseline["schema_version"] != head["schema_version"]
  warn "baseline schema_version=#{baseline['schema_version']} != head schema_version=#{head['schema_version']}; skipping"
  exit 0
end

if baseline["scenario"] != head["scenario"]
  warn "baseline scenario=#{baseline['scenario']} != head scenario=#{head['scenario']}; skipping"
  exit 0
end

# Parse a gate spec ("30" → 0.30, "off" → nil).
def parse_pct(spec)
  return nil if spec.to_s.downcase == "off" || spec.to_s.empty?
  Float(spec) / 100.0
end

p95_pct = parse_pct(opts[:gate_p95])
p99_pct = parse_pct(opts[:gate_p99])
tput_pct = parse_pct(opts[:gate_throughput])

base_lat = baseline.dig("metrics", "latency_ms") || {}
head_lat = head.dig("metrics", "latency_ms") || {}
base_tput = baseline.dig("metrics", "ops_per_s")
head_tput = head.dig("metrics", "ops_per_s")

# Returns [pass?, delta_pct, message]. nil base / 0 base → skip (nil).
def latency_check(base, head, threshold_pct, label)
  return [ true, nil, "#{label}: missing data" ] if base.nil? || head.nil?
  return [ true, nil, "#{label}: baseline 0, can't compute delta" ] if base.to_f.zero?

  delta = (head.to_f - base.to_f) / base.to_f
  delta_pct_s = format("%+.1f%%", delta * 100)
  if threshold_pct.nil?
    [ true, delta, "#{label}: #{format('%.3f', base)}ms → #{format('%.3f', head)}ms (#{delta_pct_s}) [informational]" ]
  elsif delta > threshold_pct
    [ false, delta, "#{label}: #{format('%.3f', base)}ms → #{format('%.3f', head)}ms (#{delta_pct_s}) — exceeds +#{format('%.0f%%', threshold_pct * 100)} threshold" ]
  else
    [ true, delta, "#{label}: #{format('%.3f', base)}ms → #{format('%.3f', head)}ms (#{delta_pct_s})" ]
  end
end

def throughput_check(base, head, threshold_pct)
  return [ true, nil, "ops/s: missing data" ] if base.nil? || head.nil?
  return [ true, nil, "ops/s: baseline 0, can't compute delta" ] if base.to_f.zero?

  delta = (head.to_f - base.to_f) / base.to_f
  delta_pct_s = format("%+.1f%%", delta * 100)
  if threshold_pct.nil?
    [ true, delta, "ops/s: #{format('%.1f', base)} → #{format('%.1f', head)} (#{delta_pct_s}) [informational]" ]
  elsif delta < -threshold_pct
    [ false, delta, "ops/s: #{format('%.1f', base)} → #{format('%.1f', head)} (#{delta_pct_s}) — drops more than #{format('%.0f%%', threshold_pct * 100)}" ]
  else
    [ true, delta, "ops/s: #{format('%.1f', base)} → #{format('%.1f', head)} (#{delta_pct_s})" ]
  end
end

results = []
results << latency_check(base_lat["p50"], head_lat["p50"], nil, "p50")
results << latency_check(base_lat["p95"], head_lat["p95"], p95_pct, "p95")
results << latency_check(base_lat["p99"], head_lat["p99"], p99_pct, "p99")
results << throughput_check(base_tput, head_tput, tput_pct)

failed = results.reject { |r| r[0] }

puts
puts "Benchmark vs baseline (scenario=#{head['scenario']})"
puts "  baseline: sha=#{baseline.dig('git', 'sha') || '?'} ruby=#{baseline.dig('env', 'ruby')} pg=#{baseline.dig('env', 'postgres_server_version')}"
puts "  head:     sha=#{head.dig('git', 'sha') || '?'} ruby=#{head.dig('env', 'ruby')} pg=#{head.dig('env', 'postgres_server_version')}"
results.each { |_, _, msg| puts "  #{msg}" }
puts

# GitHub Actions step summary — renders as markdown on the run page.
if (summary_path = ENV["GITHUB_STEP_SUMMARY"]) && !summary_path.empty?
  File.open(summary_path, "a") do |f|
    f.puts "### Benchmark vs baseline — `#{head['scenario']}`"
    f.puts
    f.puts "| metric | baseline | head | delta |"
    f.puts "|---|---|---|---|"
    rows = [
      [ "p50", base_lat["p50"], head_lat["p50"], "ms" ],
      [ "p95", base_lat["p95"], head_lat["p95"], "ms" ],
      [ "p99", base_lat["p99"], head_lat["p99"], "ms" ],
      [ "ops/s", base_tput, head_tput, "" ]
    ]
    rows.each do |label, b, h, unit|
      delta_s =
        if b && h && b.to_f != 0
          format("%+.1f%%", ((h.to_f - b.to_f) / b.to_f) * 100)
        else
          "—"
        end
      b_s = b ? "#{format('%.3f', b)}#{unit}" : "—"
      h_s = h ? "#{format('%.3f', h)}#{unit}" : "—"
      f.puts "| #{label} | #{b_s} | #{h_s} | #{delta_s} |"
    end
    f.puts
    f.puts "Gates: p95=#{opts[:gate_p95]}%, p99=#{opts[:gate_p99]}, throughput=#{opts[:gate_throughput]}"
    if failed.any?
      f.puts
      f.puts "**Regressions:**"
      failed.each { |_, _, msg| f.puts "- #{msg}" }
    end
  end
end

if failed.any?
  warn "regression: #{failed.size} gated metric(s) exceeded threshold"
  exit 1
end
