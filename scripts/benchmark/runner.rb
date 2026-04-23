# frozen_string_literal: true

require_relative "metrics"

module Benchmark
  # ANSI color + box-drawing helpers. All output falls back to plain text when
  # stdout isn't a TTY or NO_COLOR is set.
  module Pretty
    module_function

    def color?
      return @color if defined?(@color)
      @color = $stdout.tty? && ENV["NO_COLOR"].to_s.empty?
    end

    CODES = {
      reset: 0, bold: 1, dim: 2,
      red: 31, green: 32, yellow: 33, blue: 34, magenta: 35, cyan: 36, gray: 90,
      bright_green: 92, bright_cyan: 96, bright_white: 97
    }.freeze

    def paint(text, *styles)
      return text unless color?
      seq = styles.map { |s| CODES.fetch(s) }.join(";")
      "\e[#{seq}m#{text}\e[0m"
    end

    def rule(width, style: :gray)
      paint("─" * width, style)
    end

    def box(title, body_lines, width: 72, title_style: [ :bold, :cyan ])
      inner = width - 2
      title_str = " #{title} "
      pad = inner - visible_width(title_str)
      top = "┌" + "─" + paint(title_str, *title_style) + ("─" * [ pad - 1, 0 ].max) + "┐"
      bottom = "└" + ("─" * inner) + "┘"
      out = [ paint("┌", :gray).sub("┌", "") ] # placeholder
      out = [ top_line(title, title_style, width) ]
      body_lines.each { |ln| out << body_line(ln, width) }
      out << paint("└" + ("─" * inner) + "┘", :gray)
      out.join("\n")
    end

    def top_line(title, title_style, width)
      inner = width - 2
      t = " #{title} "
      vis = visible_width(t)
      left = paint("┌─", :gray)
      middle = paint(t, *title_style)
      right = paint(("─" * (inner - 1 - vis)) + "┐", :gray)
      left + middle + right
    end

    def body_line(text, width)
      # Line = │ + 2 space + content + pad + 2 space + │  (= width total)
      inner_width = width - 6
      pad = inner_width - visible_width(text)
      pad = 0 if pad.negative?
      "#{paint('│', :gray)}  #{text}#{' ' * pad}  #{paint('│', :gray)}"
    end

    def visible_width(str)
      str.gsub(/\e\[[\d;]*m/, "").length
    end

    # Horizontal bar for latency visualization. `frac` in [0, 1].
    def bar(frac, width: 24, style: :cyan)
      frac = 0.0 if frac.nan? || frac.negative?
      frac = 1.0 if frac > 1.0
      filled = (frac * width).round
      full = "█" * filled
      empty = "·" * (width - filled)
      paint(full, style) + paint(empty, :gray)
    end
  end

  # Drives a scenario across a thread pool for a fixed number of iterations.
  # Splits iterations evenly across threads, hands each its own Metrics bucket,
  # and checks out an AR connection per thread so ops don't contend on one.
  class Runner
    BOX_WIDTH = 72

    attr_reader :scenario, :opts

    def initialize(scenario, opts)
      @scenario = scenario
      @opts = opts
    end

    def run
      banner
      scenario.setup
      warmup_stats = opts[:warmup].positive? ? timed_warmup : nil
      metrics, wall = measure(opts[:iterations])
      scenario.teardown
      report(metrics, wall, warmup_stats)
      sanity_check
      metrics
    end

    private

    def timed_warmup
      t0 = monotonic_ns
      measure(opts[:warmup], record: false)
      { wall_ns: monotonic_ns - t0 }
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
      name = scenario.class.name.split("::").last
      title = "Stern Benchmark · #{name}"
      puts
      puts Pretty.paint("  " + title, :bold, :bright_white)
      puts Pretty.paint("  " + ("━" * title.length), :bright_cyan)
      puts
      puts Pretty.paint("  configuration", :bold, :gray)
      rows = [
        [ "threads",    opts[:threads].to_s,    "warmup",    opts[:warmup].to_s ],
        [ "iterations", opts[:iterations].to_s, "merchants", opts[:merchants].to_s ],
        [ "currency",   opts[:currency].to_s,   "chart",     (ENV["STERN_CHART"] || "general") ]
      ]
      rows.each do |k1, v1, k2, v2|
        puts "    " \
             "#{Pretty.paint(k1.ljust(12), :gray)}#{Pretty.paint(v1.ljust(12), :bright_white)}" \
             "#{Pretty.paint(k2.ljust(12), :gray)}#{Pretty.paint(v2, :bright_white)}"
      end
      puts
    end

    def report(metrics, wall_ns, warmup_stats)
      wall_s = wall_ns / 1e9
      tput = metrics.total / wall_s
      ok = metrics.ok_count
      err = metrics.errors.values.sum
      total = metrics.total

      if warmup_stats
        puts "  #{Pretty.paint('warmup', :gray)}     " \
             "#{Pretty.paint('done', :green)} " \
             "#{Pretty.paint("in #{format('%.2fs', warmup_stats[:wall_ns] / 1e9)}", :dim)}"
      end
      puts "  #{Pretty.paint('measure', :gray)}    " \
           "#{Pretty.paint('done', :green)} " \
           "#{Pretty.paint("in #{format('%.2fs', wall_s)}", :dim)}"
      puts

      # Throughput highlight box
      tput_str = Pretty.paint(format("%.1f", tput), :bold, :bright_green)
      unit     = Pretty.paint("ops/s", :dim)
      ok_frac  = total.positive? ? ok.to_f / total : 1.0
      ok_color = err.zero? ? :bright_green : (ok_frac >= 0.99 ? :yellow : :red)
      status_str = Pretty.paint("#{ok} ok", ok_color)
      status_str += " " + Pretty.paint("· #{err} err", :red) if err.positive?
      status_str += Pretty.paint(" / #{total}", :dim)

      headline = "#{tput_str} #{unit}"
      pad_spaces = BOX_WIDTH - 6 - Pretty.visible_width(headline) - Pretty.visible_width(status_str)
      pad_spaces = 2 if pad_spaces < 2
      line = headline + (" " * pad_spaces) + status_str
      puts Pretty.top_line("Throughput", [ :bold, :bright_cyan ], BOX_WIDTH)
      puts Pretty.body_line("", BOX_WIDTH)
      puts Pretty.body_line(line, BOX_WIDTH)
      puts Pretty.body_line("", BOX_WIDTH)
      puts Pretty.paint("└" + ("─" * (BOX_WIDTH - 2)) + "┘", :gray)
      puts

      # Latency table with bars, scaled to p99 so outliers don't crush the graph
      samples = [
        [ "min",  metrics.min_ns,           :green ],
        [ "p50",  metrics.percentile(50),   :green ],
        [ "mean", metrics.mean_ns,          :cyan  ],
        [ "p95",  metrics.percentile(95),   :yellow ],
        [ "p99",  metrics.percentile(99),   :magenta ],
        [ "max",  metrics.max_ns,           :red ]
      ]
      scale = samples.map { |s| s[1] }.max.to_f
      scale = 1.0 if scale.zero?

      puts Pretty.paint("  latency", :bold, :gray) + Pretty.paint("  (ms)", :dim)
      samples.each do |label, ns, style|
        ms = ns / 1e6
        frac = ns / scale
        puts "    " \
             "#{Pretty.paint(label.ljust(6), :gray)}" \
             "#{Pretty.paint(format('%9.3f', ms), :bright_white)}  " \
             "#{Pretty.bar(frac, style: style)}"
      end
      puts

      return if metrics.errors.empty?

      puts Pretty.paint("  errors", :bold, :red)
      width = metrics.errors.keys.map(&:length).max
      metrics.errors.sort_by { |_, v| -v }.each do |klass, n|
        puts "    " \
             "#{Pretty.paint(klass.ljust(width), :red)}  " \
             "#{Pretty.paint(n.to_s, :bright_white)}"
      end
      puts
    end

    def sanity_check
      ok = ::Stern::Doctor.amount_consistent?
      mark = ok ? Pretty.paint("✓", :bright_green) : Pretty.paint("✗", :red)
      label = Pretty.paint("ledger", :bold, :gray)
      check = Pretty.paint("Stern::Doctor.amount_consistent?", :dim)
      status = ok ? Pretty.paint("consistent", :green) : Pretty.paint("INCONSISTENT", :bold, :red)
      puts "  #{mark} #{label}  #{check}  #{status}"
      puts
      warn Pretty.paint("WARNING: ledger amount sum is nonzero", :bold, :red) unless ok
    end
  end
end
