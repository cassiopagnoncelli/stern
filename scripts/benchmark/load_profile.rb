#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs a heavy-duty benchmark and samples host + Postgres counters alongside it,
# then prints a summary that points at the likely bottleneck. The benchmark
# itself is untouched — this is a pure observer.
#
# Default benchmark: `charge_payment` via the existing benchmark runner, with
# the same env knobs (`BENCHMARK_OP`, `BENCHMARK_THREADS`, ...) the Makefile
# already exposes for `benchmark-one`.
#
# Why this exists: when a benchmark looks idle on CPU / RAM / network, the
# workload is almost certainly parked inside Postgres — waiting on advisory
# locks, on WAL fsync, on row locks, or queued on the AR connection pool.
# Those are invisible to `top`/`htop` but obvious in `pg_stat_activity` and
# `pg_locks`. This script collects both views every second and aggregates.
#
# Usage:
#   bundle exec ruby scripts/benchmark/load_profile.rb
#   BENCHMARK_OP=transfer_balance BENCHMARK_THREADS=16 \
#     bundle exec ruby scripts/benchmark/load_profile.rb
#
# Env:
#   BENCHMARK_OP          Scenario (default: charge_payment)
#   BENCHMARK_THREADS     Concurrent workers (default: 8)
#   BENCHMARK_ITERATIONS  Total ops (default: 2000)
#   BENCHMARK_WARMUP      Warmup ops (default: 200)
#   BENCHMARK_MERCHANTS   Distinct gids to rotate through (default: 16)
#   SAMPLE_HZ             Samples per second (default: 1)
#   DATABASE_URL          Postgres URL (otherwise parsed from dummy yml)

require "pg"
require "yaml"
require "erb"
require "json"

ROOT          = File.expand_path("../..", __dir__)
RUN_SCRIPT    = File.join(ROOT, "scripts", "benchmark", "run.rb")
DB_YAML_PATH  = File.join(ROOT, "spec", "dummy", "config", "database.yml")

SAMPLE_HZ     = (ENV["SAMPLE_HZ"] || "1").to_f
SAMPLE_PERIOD = 1.0 / SAMPLE_HZ

BENCH_OPTS = {
  op:         ENV["BENCHMARK_OP"]         || "charge_payment",
  threads:    ENV["BENCHMARK_THREADS"]    || "8",
  iterations: ENV["BENCHMARK_ITERATIONS"] || "2000",
  warmup:     ENV["BENCHMARK_WARMUP"]     || "200",
  merchants:  ENV["BENCHMARK_MERCHANTS"]  || "16"
}.freeze

# ─── ANSI helpers ─────────────────────────────────────────────────────────────

def color?
  @color ||= ($stdout.tty? && ENV["NO_COLOR"].to_s.empty?) ? :y : :n
  @color == :y
end

def paint(s, *codes)
  return s unless color?
  "\e[#{codes.join(';')}m#{s}\e[0m"
end

def bold(s);    paint(s, 1);    end
def dim(s);     paint(s, 2);    end
def green(s);   paint(s, 32);   end
def yellow(s);  paint(s, 33);   end
def cyan(s);    paint(s, 36);   end
def red(s);     paint(s, 31);   end
def magenta(s); paint(s, 35);   end

# ─── DB connection ────────────────────────────────────────────────────────────

def connect_pg
  if (url = ENV["DATABASE_URL"]) && !url.empty?
    return PG.connect(url)
  end

  raw = ERB.new(File.read(DB_YAML_PATH)).result
  cfg = YAML.safe_load(raw, aliases: true, permitted_classes: [ Symbol ])
  dev = cfg.fetch("development")

  PG.connect(
    host:     ENV["DB_HOST"] || dev["host"] || "localhost",
    port:     ENV["DB_PORT"] || dev["port"],
    dbname:   dev.fetch("database"),
    user:     ENV["DB_USER"] || dev["username"] || ENV["USER"],
    password: ENV["DB_PASSWORD"] || dev["password"]
  )
end

# ─── Process tree sampling ────────────────────────────────────────────────────

# Returns [total_cpu_pct, total_rss_kb] across `root_pid` and its descendants.
# Uses BSD `ps` which is available on macOS and Linux.
def sample_process_tree(root_pid)
  out = `ps -A -o pid=,ppid=,%cpu=,rss= 2>/dev/null`
  rows = out.each_line.map do |line|
    pid, ppid, cpu, rss = line.split
    [ pid.to_i, ppid.to_i, cpu.to_f, rss.to_i ]
  end

  by_parent = rows.group_by { |_, ppid, _, _| ppid }
  in_tree   = {}
  queue     = [ root_pid ]
  while (pid = queue.shift)
    next if in_tree.key?(pid)
    row = rows.find { |p, _, _, _| p == pid }
    next unless row
    in_tree[pid] = row
    (by_parent[pid] || []).each { |child| queue << child[0] }
  end

  cpu = in_tree.values.sum { |_, _, c, _| c }
  rss = in_tree.values.sum { |_, _, _, r| r }
  [ cpu, rss ]
end

# ─── Postgres sampling ────────────────────────────────────────────────────────

WAIT_SQL = <<~SQL
  SELECT
    COALESCE(wait_event_type, 'CPU') AS wait_type,
    COALESCE(wait_event,      'on-cpu') AS wait_event,
    count(*) AS n
  FROM pg_stat_activity
  WHERE state = 'active'
    AND datname = $1
    AND pid <> $2
  GROUP BY 1, 2
SQL

LOCKS_SQL = <<~SQL
  SELECT locktype, granted, count(*) AS n
  FROM pg_locks
  WHERE database = (SELECT oid FROM pg_database WHERE datname = $1)
     OR locktype = 'advisory'
  GROUP BY 1, 2
SQL

def sample_pg(conn, datname, self_pid)
  waits = conn.exec_params(WAIT_SQL, [ datname, self_pid ]).to_a.map do |r|
    { type: r["wait_type"], event: r["wait_event"], n: r["n"].to_i }
  end
  locks = conn.exec_params(LOCKS_SQL, [ datname ]).to_a.map do |r|
    { locktype: r["locktype"], granted: (r["granted"] == "t"), n: r["n"].to_i }
  end
  [ waits, locks ]
end

# ─── Sampler ──────────────────────────────────────────────────────────────────

Sample = Struct.new(:ts, :cpu, :rss_kb, :waits, :locks)

def run_sampler(root_pid:, conn:, datname:, self_pid:, stop_flag:)
  samples = []
  err = nil
  thread = Thread.new do
    Thread.current.report_on_exception = false
    until stop_flag[:stop]
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        cpu, rss = sample_process_tree(root_pid)
        waits, locks = sample_pg(conn, datname, self_pid)
        samples << Sample.new(t0, cpu, rss, waits, locks)
      rescue => e
        err = e
        break
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      sleep([ SAMPLE_PERIOD - elapsed, 0 ].max)
    end
  end
  [ thread, samples, -> { err } ]
end

# ─── Aggregation + report ─────────────────────────────────────────────────────

def summarize_resources(samples)
  return nil if samples.empty?
  cpus = samples.map(&:cpu)
  rss  = samples.map(&:rss_kb)
  {
    cpu_avg:  cpus.sum / cpus.size,
    cpu_peak: cpus.max,
    rss_avg_mb:  (rss.sum.to_f / rss.size) / 1024.0,
    rss_peak_mb: rss.max.to_f / 1024.0
  }
end

def summarize_waits(samples)
  totals = Hash.new(0)
  backend_samples = 0
  samples.each do |s|
    s.waits.each { |w| totals["#{w[:type]} / #{w[:event]}"] += w[:n]; backend_samples += w[:n] }
  end
  return [ [], 0 ] if backend_samples.zero?
  rows = totals.map { |k, n| { label: k, n: n, pct: n.to_f / backend_samples } }
              .sort_by { |r| -r[:n] }
  [ rows, backend_samples ]
end

def summarize_locks(samples)
  totals = Hash.new(0)
  samples.each do |s|
    s.locks.each do |l|
      key = "#{l[:locktype]} (#{l[:granted] ? 'granted' : 'waiting'})"
      totals[key] += l[:n]
    end
  end
  totals.map { |k, n| { label: k, n: n } }.sort_by { |r| -r[:n] }
end

def classify(waits, resources)
  return :no_data if waits.empty?
  pct = ->(needle) { waits.select { |w| w[:label].include?(needle) }.sum { |w| w[:pct] } }

  return :advisory_lock if pct.call("Lock / advisory") > 0.30
  return :wal_fsync     if pct.call("WALSync") + pct.call("WALWrite") > 0.30
  return :row_lock      if pct.call("Lock / transactionid") + pct.call("Lock / tuple") > 0.30
  return :client_idle   if pct.call("Client / ClientRead") > 0.50
  return :cpu_bound     if (resources && resources[:cpu_avg] > 75.0)
  :mixed
end

VERDICT = {
  advisory_lock: [
    :red,
    "Advisory-lock contention",
    "Threads serialize on pg_advisory_xact_lock for the same (book, gid, currency) tuple.",
    "Reduce contention with more --merchants, fewer --threads, or shard the lock key."
  ],
  wal_fsync: [
    :yellow,
    "WAL fsync (commit cost)",
    "Most time is spent flushing WAL on COMMIT. macOS APFS fsync is slow.",
    "Batch operations per transaction, or set synchronous_commit=off in dev (NOT prod)."
  ],
  row_lock: [
    :red,
    "Row-level lock contention",
    "Backends are waiting on transactionid / tuple locks — they fight over the same rows.",
    "Look at the per-op write set; consider narrower row scope or different sharding."
  ],
  client_idle: [
    :yellow,
    "Client-side stall",
    "Backends are idle waiting on Ruby to send the next query. The DB is not the bottleneck.",
    "Suspect AR pool starvation (RAILS_MAX_THREADS < --threads), GVL, or Ruby-side latency."
  ],
  cpu_bound: [
    :cyan,
    "CPU-bound",
    "Process-tree CPU is saturated; DB looks healthy.",
    "Profile Ruby with stackprof / rbspy to find the hot path."
  ],
  mixed: [
    :cyan,
    "No single dominant signal",
    "Workload appears balanced across CPU, commit, and lock waits.",
    "Try increasing --threads or --iterations to amplify the bottleneck before re-profiling."
  ],
  no_data: [
    :red,
    "No backends observed",
    "The sampler never saw an active backend on this database during the run.",
    "Confirm the benchmark is hitting the same database the sampler is connected to."
  ]
}.freeze

def print_report(samples:, exit_status:, wall_s:)
  res = summarize_resources(samples)
  waits, backend_samples = summarize_waits(samples)
  locks = summarize_locks(samples)
  verdict = classify(waits, res)
  v_color, v_title, v_body, v_hint = VERDICT.fetch(verdict)

  puts
  puts bold("  Load profile summary")
  puts dim("  ─────────────────────────────────────────────────────────────────────")
  puts "  wall time      #{format('%.2fs', wall_s)}"
  puts "  samples        #{samples.size} @ #{SAMPLE_HZ} Hz  (benchmark exit: #{exit_status})"
  puts

  if res
    puts bold("  Host (benchmark process tree)")
    puts "    CPU%   avg #{format('%6.1f', res[:cpu_avg])}    peak #{format('%6.1f', res[:cpu_peak])}"
    puts "    RSS    avg #{format('%6.1f MB', res[:rss_avg_mb])} peak #{format('%6.1f MB', res[:rss_peak_mb])}"
    puts
  end

  if waits.any?
    puts bold("  Postgres wait events (backend-samples, top 10)")
    width = [ waits.map { |w| w[:label].length }.max, 30 ].max
    waits.first(10).each do |w|
      bar_len = (w[:pct] * 30).round
      bar = "█" * bar_len + dim("·" * (30 - bar_len))
      puts "    %-#{width}s  %5d  %5.1f%%  %s" % [ w[:label], w[:n], w[:pct] * 100, bar ]
    end
    puts dim("    total backend-samples: #{backend_samples}")
    puts
  else
    puts dim("  Postgres wait events: (no active backends observed)")
    puts
  end

  if locks.any?
    puts bold("  pg_locks distribution (sample-totals)")
    locks.first(8).each do |l|
      puts "    %-32s  %d" % [ l[:label], l[:n] ]
    end
    puts
  end

  puts bold("  Verdict")
  badge = case v_color
          when :red    then red("●")
          when :yellow then yellow("●")
          when :green  then green("●")
          else cyan("●")
          end
  puts "    #{badge} #{bold(v_title)}"
  puts "      #{v_body}"
  puts dim("      next: #{v_hint}")
  puts
end

# ─── Main ─────────────────────────────────────────────────────────────────────

def main
  conn     = connect_pg
  datname  = conn.exec("SELECT current_database()").first["current_database"]
  self_pid = conn.exec("SELECT pg_backend_pid()").first["pg_backend_pid"].to_i

  cmd = [
    "bundle", "exec", "ruby", RUN_SCRIPT,
    "--op=#{BENCH_OPTS[:op]}",
    "--threads=#{BENCH_OPTS[:threads]}",
    "--iterations=#{BENCH_OPTS[:iterations]}",
    "--warmup=#{BENCH_OPTS[:warmup]}",
    "--merchants=#{BENCH_OPTS[:merchants]}"
  ]
  child_env = { "RAILS_MAX_THREADS" => BENCH_OPTS[:threads] }

  puts bold("  Load profile")
  puts dim("  ─────────────────────────────────────────────────────────────────────")
  puts "  benchmark      #{BENCH_OPTS[:op]}  " \
       "(threads=#{BENCH_OPTS[:threads]}, " \
       "iter=#{BENCH_OPTS[:iterations]}, " \
       "merchants=#{BENCH_OPTS[:merchants]})"
  puts "  database       #{datname}"
  puts "  sample rate    #{SAMPLE_HZ} Hz"
  puts

  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  child_pid  = Process.spawn(child_env, *cmd, chdir: ROOT)
  stop_flag  = { stop: false }
  thread, samples, err_lookup = run_sampler(
    root_pid: child_pid, conn: conn, datname: datname,
    self_pid: self_pid, stop_flag: stop_flag
  )

  _, status = Process.wait2(child_pid)
  stop_flag[:stop] = true
  thread.join(2)
  wall_s = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

  if (e = err_lookup.call)
    warn red("  sampler error: #{e.class}: #{e.message}")
  end

  print_report(samples: samples, exit_status: status.exitstatus.to_s, wall_s: wall_s)
  exit(status.exitstatus || 1)
ensure
  conn&.close
end

main
