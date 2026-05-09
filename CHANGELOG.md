# Changelog

All notable changes to Stern are documented in this file.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **Time-zone correctness in query defaults.** `BalanceQuery`,
  `BalanceSheetQuery`, `EntriesQuery`, `SumEntriesQuery`,
  `OutstandingBalanceQuery`, `BookBalancesQuery`, `Entry.last_entry`,
  `NoFutureTimestamp`, and the `Stern.balance` / `Stern.outstanding_balance`
  module helpers all defaulted their `timestamp` parameter to
  `DateTime.current`, which ignores `Time.zone`. Admin callers that omitted
  the parameter got a non-zone-aware "now" — silently wrong for time-windowing
  in non-UTC tenants. Replaced with `Time.current`, which respects the
  per-request `Time.use_zone(...)` set by `AuthenticatedController`.

### Changed

- **Stakeholder-pair operations now use a class-level `performs_stakeholder_pair`
  macro** instead of hand-written `target_tuples` / `perform` / `runtime_check`
  triplets. Seventeen ops collapsed from ~25 lines of dispatch boilerplate to a
  single declaration: `AdjustBalance`, `SettleBalance`, `WithholdBalance`,
  `ApplyCredit`, `AddCredit`, `Deposit`, `ConfirmWithdrawal`,
  `ReverseChargeback`, `UnlockBalance`, `ReleaseWithheldBalance`,
  `ReverseWithdrawal`, `LockBalance`, `LockWithdrawal`, `CancelWithdrawal`,
  `SplitPayment`, `CancelRefund`, `ReverseRefund`. Pure refactor — emits the
  same `EntryPair.add_*` calls and same `Stern::InsufficientFunds` messages,
  so existing callers and specs are unaffected. Multi-pair / two-stakeholder
  ops (`TransferBalance`, `ReintegratePayment`, fee ops) are unchanged.
- **`Stern::Divest` now raises `Stern::InsufficientFunds`** when the
  per-investment `customer_investment` balance is negative and
  `allow_overdraft` is false. Previously the op silently no-op'd while still
  recording an `Operation` audit row, leaving callers with no signal that the
  divestment hadn't happened. The balance read and check now run in
  `runtime_check`, so a raise rolls back the audit row alongside any entries.
  A zero balance is still treated as a no-op (idempotent re-divest).
- **Lint guard against `DateTime`.** Enabled `Style/DateTime` in
  `.rubocop.yml` (excluding `spec/` and the SOP files) to keep new
  `DateTime.current` / `DateTime.parse` usages from creeping back in.

## [1.8.0] — 2026-05-09

Withdrawal-flow rework. The lifecycle now exposes explicit forward operations
for every transition out of `wdw_*_locked` / `wdw_*_confirmed`, with intent
preserved in the audit trail instead of inferred from a sign flip. The same
shape is now extended to `lock_*_balance` via `UnlockBalance` and to
`withhold_*_balance` via `ReleaseWithheldBalance`.

### Added

- **`Stern.in_progress_timeout_seconds`.** Configurable replacement for the
  hardcoded `IN_PROGRESS_TIMEOUT_IN_SECONDS = 600` in
  `ScheduledOperationService.clear_in_progress`. Default is still 600s, so
  behavior is unchanged unless overridden. Set it via the
  `STERN_IN_PROGRESS_TIMEOUT_SECONDS` env var or explicit assignment
  (`Stern.in_progress_timeout_seconds = 1800`); explicit assignment wins.
  Bump past your longest expected op runtime when running legitimately slow
  ops so the janitor doesn't treat them as crashed.
- **`Stern::CancelWithdrawal`.** Releases an in-flight lock back to
  `*_available` (`wdw_*_locked → *_available`). Use before settlement; the
  pre-check raises `Stern::InsufficientFunds` when the cancel exceeds the
  current locked balance.
- **`Stern::ReverseWithdrawal`.** Reverses a confirmed withdrawal back to
  `*_available` (`wdw_*_confirmed → *_available`), for post-settlement
  rejects (e.g. bank-side bounce). Same exception shape as Cancel.
- **`Stern::UnlockBalance`.** Releases a previously locked balance back to
  `*_available` (`*_locked → *_available`). Inverse of `LockBalance`; no
  `confirmed` companion stage exists for `*_locked`, so a single inverse
  pair suffices. Pre-check raises `Stern::InsufficientFunds` when the
  unlock exceeds the current locked balance.
- **`Stern::ReleaseWithheldBalance`.** Releases a previously withheld
  balance back to `*_available` (`*_withheld → *_available`). Inverse of
  `WithholdBalance`; like `*_locked`, `*_withheld` has no `confirmed`
  companion, so a single inverse pair suffices. Pre-check raises
  `Stern::InsufficientFunds` when the release exceeds the current
  withheld balance.
- **`Stern::CancelRefund`.** Operation class for the `cancel_refund_*`
  books introduced in 1.5.0. Pre-check raises `Stern::InsufficientFunds`
  when the cancel exceeds the current locked refund balance.
- **`allow_overdraft` flag on `LockWithdrawal`, `LockBalance`, `Divest`,
  and `TransferBalance`.** Defaults to `false` (the safe path); set `true`
  to authorize a write that would otherwise be rejected. Replaces the
  prior `capped` flag on `LockWithdrawal` and `Divest` (polarity flipped).
  On `LockBalance` it gates a new pre-check that raises
  `Stern::InsufficientFunds` when the lock would exceed the stakeholder's
  per-gid available balance.
- **DB-level backstop on `wdw_*_locked` / `wdw_*_confirmed`.** Both books
  are now `non_negative: true`, mirroring `refund_locked` and
  `chargeback_locked`. Translates an over-debit (concurrent or otherwise)
  into `Stern::BalanceNonNegativeViolation`.
- **DB-level backstop on `*_locked`.** `merchant_locked`, `partner_locked`,
  and `customer_locked` are now `non_negative: true`, behind
  `UnlockBalance`'s pre-check.
- **DB-level backstop on `*_withheld`.** `merchant_withheld`,
  `partner_withheld`, and `customer_withheld` are now `non_negative: true`,
  behind `ReleaseWithheldBalance`'s pre-check.

### Changed

- **`LockWithdrawal` raises `Stern::InsufficientFunds`** (was a generic
  `ArgumentError` with `"larger than available balance"`) when the cap is
  hit. Aligns with the existing `BalanceNonNegativeViolation` taxonomy.
- **`TransferBalance` raises `Stern::InsufficientFunds`** for the same
  reason. The drain semantic (`amount: nil`) is now rejected upfront when
  combined with `allow_overdraft: true`.
- **`LockWithdrawal#amount` must be positive** — the validator is now
  `greater_than: 0` (was `other_than: 0`).
- **`LockBalance#amount` must be positive** — the validator is now
  `greater_than: 0` (was `other_than: 0`). The negative-amount unlock path
  is removed; use `UnlockBalance` instead.
- **`WithholdBalance#amount` must be positive** — the validator is now
  `greater_than: 0` (was `other_than: 0`). The negative-amount release
  path is removed; use `ReleaseWithheldBalance` instead.

### Removed

- **Negative-amount unlock path on `LockWithdrawal`.** Use
  `CancelWithdrawal` for pre-settlement release, `ReverseWithdrawal` for
  post-settlement reversal.
- **Negative-amount unlock path on `LockBalance`.** Use `UnlockBalance`.
- **Negative-amount release path on `WithholdBalance`.** Use
  `ReleaseWithheldBalance`.
- **`capped` flag on `LockWithdrawal` and `Divest`.** Renamed to
  `allow_overdraft`; default behavior is unchanged
  (`capped: true` ↔ `allow_overdraft: false`).

### Migration notes

Hosts that pass `capped:` to `LockWithdrawal` or `Divest`, rescue
`ArgumentError` from `LockWithdrawal` / `TransferBalance` for funds-shortage
errors, rely on `LockWithdrawal.new(amount: -X)` /
`LockBalance.new(amount: -X)` / `WithholdBalance.new(amount: -X)` to
unlock or release, or call `LockBalance` with an amount exceeding the
per-gid available balance will need to update. `LockBalance` callers
that intentionally overdraft can pass `allow_overdraft: true`. The
chart-level `non_negative` additions take effect on the next
`db/seeds/books.rb` run (test suite seeds in `before(:suite)`).

## [1.7.0] — 2026-05-09

Audit trail and idempotency hardening. Operations now record every
invocation in a queryable attempts table, and the idempotency layer
rejects param-mismatch with a typed exception instead of silently
returning a stale result.

### Added

- **`Stern::OperationAttempt`.** Append-only audit log for every
  operation invocation: operation name, params (JSON), `idem_key`,
  status (`pending` / `succeeded` / `failed`), timing. Migrated by
  `db/migrate/20260509000000_add_stern_operation_attempts.rb`.
- **Admin attempts search.** `/stern/admin/attempts` — filter by
  operation name, status, `idem_key`, and date range. Date filter uses
  the IDP passport zone via `AuthenticatedController`. Backed by
  `Stern::OperationAttemptsQuery` with paginated results
  (5 / 25 / 100 / 500 per page).
- **`Stern::IdempotencyConflict`.** Typed exception raised when a
  retried request reuses an `idem_key` with different params. The
  previous behavior — silent acceptance of the prior result — masked
  caller bugs.
- **Tuple-level locking when applying credits.** `ApplyCredit` now
  acquires per-tuple advisory locks like other balance-mutating ops,
  closing a concurrent-credit race.
- **Fail-fast documentation** in the README covering
  `Stern::IdempotencyConflict` semantics and recommended retry
  patterns.

### Changed

- **`find_existing_operation` deep-compares params as JSON** rather
  than by Ruby hash equality, eliminating false-positive idempotency
  conflicts caused by key ordering or symbol-vs-string differences.
- **Race-loser path validates winner params** before returning, so a
  losing thread on an `idem_key` race can't return a
  partially-mismatched success.
- **`non_negative` constraint name** promoted to a single Ruby
  constant, used by the PL/pgSQL trigger and the Ruby exception
  translator.
- **`BaseOperation` display layer dropped** in favor of letting
  callers format attempts as needed.

### Migration notes

Hosts must run `bundle exec rake db:migrate` to create the
`stern_operation_attempts` table. Code that catches idempotency
conflicts can keep its existing rescue, but should narrow to
`Stern::IdempotencyConflict` for clearer intent.

## [1.6.0] — 2026-05-08

Balance and withdrawal operations, the investment family, and admin
UX polish. Stern now has a complete forward-only operation set
covering held / withheld / locked balances and the investment
lifecycle, plus a balance sheet with named presets and zone-correct
date picking.

### Added

- **Balance ops.** `LockBalance`, `WithholdBalance`, `SettleBalance`,
  `AdjustBalance`, `TransferBalance`, `Deposit`, `AddCredit`,
  `ApplyCredit`. Each declares `target_tuples` for per-tuple advisory
  locking.
- **Withdrawal forward ops.** `LockWithdrawal`, `ConfirmWithdrawal`,
  `ChargeWithdrawalFee`. Introduces the `capped:` flag (renamed to
  `allow_overdraft:` in 1.8.0).
- **Investment family.** `Invest`, `Divest`, `Trade`. Books for
  `investment_invest`, `investment_trade`, `investment_trade_operation`,
  `investment_trade_fee`. Trade has a per-operation protection cap.
- **Balance entry pairs** in `config/charts/general.yaml` covering the
  new `*_locked`, `*_withheld`, `*_available`, `*_settled` transitions.
- **Balance sheet presets** at `config/balance_sheet_presets.yml` —
  named windows (today, 7d, 30d, MTD, YTD) selectable from the date
  range picker.
- **Prefix-grouped balance sheet headers.** Book prefixes (`charge`,
  `refund`, `chargeback`, `wdw`, `investment`, etc.) map to display
  groups in `app/controllers/stern/admin/ledger_controller.rb`.
- **Luxon-based date picker** at `app/assets/builds/luxon.min.js`. JS
  presets respect the IDP passport zone (`Time.zone.tzinfo.name`),
  not the browser zone.

### Changed

- **`TransferBalance` rejects self-transfer** (same source and
  destination gid) at construction time.
- **All operations** raise on invalid currency at construction rather
  than at execution.
- **Uniqueness on entry pairs removed.** Same `(book_id, gid, pair)`
  can now appear repeatedly; uniqueness is enforced at the operation
  layer via `idem_key` instead.
- **`Provision` → `Invest`** rename across operations and books. The
  old `Allocate` / `Deallocate` drafts collapsed into `Trade`.
- **`generate_uid` removed.** Operation-level idempotency keys
  replace the previous entry-level uid generator.
- **Balance sheet headers** redesigned to surface stakeholder type,
  currency, and grouping prefix as columns.

### Migration notes

New books seed on the next `db/seeds/books.rb` run. Hosts using the
`Provision` operation must rename calls to `Invest` (and corresponding
`Deprovision` calls to `Divest`). Hosts mounting the admin must serve
the luxon asset; it ships in the gem under `app/assets/builds`.

## [1.5.0] — 2026-05-08

Operations catalog, part one: charge, refund, chargeback,
reintegrate. Introduces the stakeholder model
(merchant / partner / customer) that all subsequent operations key
off of.

### Added

- **Stakeholder model.** Merchant / partner / customer; threaded
  through every operation as `stakeholder_type`. Runtime helper
  resolves per-stakeholder books from the chart.
- **Charge family.** `ChargePayment`, `ChargePaymentFee`, `ChargePix`,
  `ChargePixFee`. Books cover `charge_bank_transfer`,
  `charge_credit_card`, `charge_debit_card`, `charge_wallet`,
  `charge_pix`, and `*_fee_<stakeholder>` variants.
- **Refund family.** `Refund`, `RefundLock`, `ChargeRefundFee`. Books
  for `lock_refund_<stakeholder>`, `cancel_refund_<stakeholder>`,
  `confirm_refund`, `settle_refund`,
  `charge_refund_fee_<stakeholder>`. (The `CancelRefund` operation
  class lands in 1.8.0; the books exist here so the chart is
  forward-compatible.)
- **Chargeback family.** `Chargeback`, `ChargeChargebackFee`. Books
  for `lock_chargeback_<stakeholder>`, `confirm_chargeback`,
  `charge_chargeback_fee_<stakeholder>`.
- **`ReintegratePayment`.** Reverses a previously settled payment
  back into stakeholder balances.
- **`SplitPayment`.** Distributes a payment across merchant and
  partner books.
- **`settle_merchant`** book and matching settlement flow, including
  a merchant payment fee.

### Changed

- **`tuples_for_pair(pair_name, gid_a, gid_b, currency)`** accepts
  two distinct gids (was one). Single-gid callers pass the same gid
  twice.
- **`method` → `payment_method`** rename on charge operations to
  avoid Ruby-keyword shadowing.
- **Validators tightened.** `greater_than: 0` on amount fields where
  appropriate; positive-only enforcement at construction.
- **Chart simplified and reorganised** through several consolidation
  passes before final shape settled.

### Migration notes

Pure addition on top of 1.4.0. New books seed on next
`db/seeds/books.rb` run. Hosts that called `tuples_for_pair` with a
single gid argument must pass it twice (the single-gid form is
removed).

## [1.4.0] — 2026-04-27

Mountable Rails engine. Adds the admin scaffolding, IdP/OIDC auth,
and gem packaging needed to mount Stern as a backoffice in a host
app. No new operations — the library API surface is unchanged from
1.3.x.

### Added

- **Tailwind admin UI** with light/dark theme — dashboard, ledger,
  balance sheet, frontend tables. Mounted under `/stern`.
- **`AuthenticatedController`.** Wraps every admin request in
  `Time.use_zone(passport_time_zone)`, resolved from the IDP user's
  `time_zone` claim (UTC fallback). Subclassing is enough; the
  `around_action` does the work. See `CLAUDE.md` for the time-zone
  conventions admin views must follow.
- **IdP / OIDC auth.** OmniAuth + OpenID Connect integration via the
  new `idp-jwt`, `omniauth_openid_connect`, and
  `omniauth-rails_csrf_protection` deps. Callback at
  `app/controllers/stern/auth/callbacks_controller.rb`.
- **Branded error pages** (4xx / 5xx).
- **Date-range picker** initial component at
  `app/views/stern/admin/shared/_date_range_picker.html.erb` (the
  luxon-driven, zone-correct preset logic lands in 1.6.0).
- **Books-modal** UI for inspecting individual book entries.
- **Currencies catalog list view** under the admin.
- **`tuples_for_pair`** signature accepts two distinct gids (also
  reused by 1.5.0's stakeholder-keyed pairs).
- **`credits` book class** in the chart.

### Changed

- **Balance-sheet query** enforces deterministic ordering by book id,
  gid, currency; gains spec coverage.
- **Stress test renamed to benchmark** for clarity about intent
  (regression measurement, not pass/fail).

### Dependencies

- Adds `propshaft >= 1.0`.
- Adds `cssbundling-rails >= 1.4`.
- Adds `idp-jwt`.
- Adds `omniauth_openid_connect ~> 0.8`.
- Adds `omniauth-rails_csrf_protection`.

### Migration notes

`bundle install` pulls the new deps. Hosts mounting the admin must
configure IdP env vars (see README). Hosts that don't mount the
admin are unaffected — the engine's library API surface is unchanged
from 1.3.x.

## [1.3.1] — 2026-04-23

SOP pipeline hardening. Bugfix release on top of 1.3.0's
scheduled-operations infrastructure. No public API changes.

### Added

- **Dead-letter queue (DLQ) for scheduled operations.** Terminally
  failed SOPs (max retries exceeded) land in a queryable DLQ instead
  of being silently dropped, preserving last-error context for
  triage.
- **Edge-case spec coverage** — two rounds covering stuck-pending
  recovery, double-pickup prevention, notify-storm behavior, and
  janitor cadence under persistent failure.
- **TCP-listen reconnection spec** verifying the LISTEN/NOTIFY
  thread recovers from connection drops with capped exponential
  backoff.

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
ops that touch no ledger state). The `tuples_for_pair(pair_name,
book_sub_gid, book_add_gid, currency)` helper covers the common
double-entry case; pass the same gid twice when both sides are indexed
by the same entity, or distinct gids for custom pairs declared under
`entry_pairs:` whose sides index different entities.

## [1.2.0] — prior release

Initial internal release line. See git history for details.
