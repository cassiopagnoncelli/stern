# Changelog

All notable changes to Stern are documented in this file.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] — 2026-04-23

A large consolidation release. The ledger is now currency-aware, concurrency
is governed by a principled three-layer advisory-lock model, and the
scheduled-operation pipeline ships with a production-ready worker loop,
LISTEN/NOTIFY low-latency pickup, and Prometheus metrics.

### Added

- **Currency-partitioned ledger.** Balances and entries are keyed on
  `(book_id, gid, currency)`. Currency codes are integers drawn from
  `config/currencies_catalog.yaml`; `Stern.cur(name_or_code, result:)`
  converts between string names and integer codes. All public APIs —
  `Stern.balance`, `Stern.outstanding_balance`, `Doctor.*`, `Repair.*`,
  `EntryPair.add_*` — take `currency` as a required argument.
- **Chart-level `non_negative: true` flag** on books. PL/pgSQL
  `create_entry_v04` refuses any write that would leave `ending_balance < 0`
  on flagged books; the violation surfaces as
  `Stern::BalanceNonNegativeViolation` (a subclass of
  `Stern::InsufficientFunds`, so `rescue InsufficientFunds` catches both
  layers cleanly).
- **`target_tuples` DSL on `BaseOperation`.** Operations declare the
  `(book, gid, currency)` tuples they read or write; `BaseOperation#call`
  acquires a per-tuple Postgres advisory lock (sorted to prevent deadlock).
  Concurrent ops on the same tuple serialize; on disjoint tuples run in
  parallel. Replaces the previous table-level `EXCLUSIVE` lock.
- **`inputs` DSL on `BaseOperation`.** Declares operation kwargs, generates
  attr accessors, drives the audit-log params hash, auto-normalizes
  `currency` from string names to integer codes.
- **`Stern::Workers::Runner`** — production-ready worker loop for scheduled
  operations. Polls, dispatches onto a fixed thread pool, runs the janitor
  (`clear_picked` + `clear_in_progress`) on a slower cadence, refreshes
  Prometheus gauges, and shuts down gracefully on SIGTERM/SIGINT. Start via
  `bundle exec rake stern:worker:start`; configurable via
  `STERN_WORKER_CONCURRENCY` / `STERN_POLL_INTERVAL` /
  `STERN_JANITOR_INTERVAL`.
- **Low-latency pickup via LISTEN/NOTIFY.** `db/functions/sop_notify_v02.sql`
  fires `NOTIFY stern_scheduled_operations_pending` on every true
  status→`pending` transition (v02 adds a transition guard over v01 so
  `update_all` over mixed rows doesn't re-notify for rows that were
  already pending). The Runner's dedicated listen thread wakes the main
  loop on each notify; auto-reconnects with capped exponential backoff
  (up to 30s); has TCP keepalive enabled (~60s dead-connection detection)
  to survive NAT/firewall half-open drops. Opt out with
  `Runner.new(listen_for_notifications: false, ...)` for PgBouncer
  transaction-pooled environments.
- **Prometheus metrics** via `lib/stern/metrics.rb`. Counters, histograms,
  and gauges for the scheduled-operation pipeline, driven by
  `ActiveSupport::Notifications`: `stern_sop_picked_total`,
  `stern_sop_terminal_total{outcome, op_name}`,
  `stern_sop_process_duration_seconds`, `stern_sop_pickup_lag_seconds`,
  `stern_sop_count{status}`. Host apps scrape by calling
  `Stern::Metrics.refresh_queue_gauges!` then rendering
  `Stern::Metrics.registry`.
- **`Stern::Chart` and `Stern::Currencies`** — typed value-object
  registries replacing raw-hash YAML lookups. `Stern.chart.book`,
  `Stern.chart.entry_pair`, `Stern.chart.book_code`, etc.
- **`Stern::ApplicationRecord.advisory_lock(book_id:, gid:, currency:)`** —
  public API for acquiring the tuple-scoped advisory lock (used by
  Repair and defense-in-depth SQL paths).
- **`Stern::Repair`** service — destructive counterpart to read-only
  `Stern::Doctor`. Houses `rebuild_book_gid_balance`, `rebuild_gid_balance`,
  `rebuild_balances`, `clear`, `requeue`. Cross-tuple rebuilds are
  piecewise but provably safe under concurrent writes (see
  `spec/services/stern/repair_concurrency_spec.rb`).
- **Hardened scheduler pipeline** — `SELECT FOR UPDATE SKIP LOCKED`
  picker, stable `idem_key`, `retry_count` with exponential backoff
  (30s × 2^retry_count, max 5 retries), `clear_in_progress` recovery for
  stuck jobs.
- **Stress + invariant specs.** 1000-thread balance contention test;
  concurrent rebuild-vs-write safety proof; mixed-layer overdraft race
  (InsufficientFunds vs BalanceNonNegativeViolation); structural
  referential-integrity helpers in `spec/support/stern/ledger_invariants.rb`.

### Changed

- **SQL functions upgraded to v04.** `create_entry` / `destroy_entry` now
  acquire the same advisory lock as `BaseOperation` (defense-in-depth for
  direct `Entry.create!` / `destroy!` callers) and enforce the chart-level
  `non_negative` flag.
- **Runner shutdown is bounded by a single `SHUTDOWN_TIMEOUT` budget** (not
  2×). Adds `pool.kill` fallback when graceful termination times out, so a
  SOP blocked on a hung external call can't hold the process open past
  the grace period. TERM/INT handlers installed by the runner are
  restored on exit.
- **`AppendOnly` concern** now only blocks updates; `create!`/`destroy!` on
  `Entry` stay as PL/pgSQL delegates.

### Fixed

- **ACCESS SHARE vs EXCLUSIVE lock bug** in the earlier cascade-protection
  scheme that allowed concurrent writes to produce identical
  `ending_balance` values on the same tuple.
- **Runner reset-race:** `@wake_event.reset` ran inside `wait_with_notify`,
  silently dropping NOTIFYs that arrived during the pick window. Now reset
  runs BEFORE `run_once` so the signal survives into the subsequent wait.
- **Runner pool.post rejection orphaned `@in_flight`:** if `post` raised
  (e.g. pool already shut down), the incremented counter was never
  decremented, and `shutdown!` spun until timeout on a phantom job.
- **Runner signal-handler Mutex risk:** `@wake_event.set` inside a
  `Signal.trap` block could deadlock on MRI. Trap now dispatches via
  `Thread.new { stop }`.
- **Janitor retry-every-tick:** a chronically-broken janitor used to
  retry on every poll interval. `@last_janitor_at` is now set on the
  rescue path too, so persistent failures respect the normal cadence.

### Dependencies

- Adds `prometheus-client` >= 4.0.
- Adds `xxhash` >= 0.5.
- Requires Ruby 3.4+, Rails 8+, PostgreSQL 13+ (for `hashtextextended`,
  `SKIP LOCKED`, advisory locks).

### Migration notes

Rails engine migrations ship new versions of the SQL functions and add
the `sop_notify_v02` trigger. Run `bundle exec rake db:migrate` after
upgrading.

Operations that previously relied on the table-level `EXCLUSIVE` lock now
need to declare `target_tuples` (or inherit the default empty array for
ops that touch no ledger state). The `tuples_for_pair(pair_name, gid,
currency)` helper covers the common double-entry case.

## [1.2.0] — prior release

Initial internal release line. See git history for details.
