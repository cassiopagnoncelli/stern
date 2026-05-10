# Stern

A scalable double-entry bookkeeping Rails engine. Stern owns the ledger: it records every
transaction as a pair of balanced entries, cascades running balances atomically in
PostgreSQL, and exposes a small operations-based API for host apps to build on.

## What it does

- **Double-entry ledger.** Every transaction creates an `EntryPair` plus two `Entry` rows
  whose amounts sum to zero. Consistency is enforced at the database level by a
  PL/pgSQL function that recomputes `ending_balance` cascades inside the same statement.
- **Append-only records.** `Entry` and `EntryPair` forbid updates and bare `destroy`. The
  only write paths are `create!` (which hits the SQL function) and `destroy!` (likewise).
- **Operations as the public API.** Host apps don't manipulate models directly; they call
  `Operation` subclasses (`ChargePix.new(...).call`) which handle idempotency, locking,
  and auditing.
- **Chart-driven.** Books and entry-pair types are declared in a single YAML file,
  selected at boot via `STERN_CHART`. Adding a book means editing the YAML and reseeding.
- **Multi-currency aware.** Currencies are indexed integers from a separate catalog, so
  amounts stay tight `bigint` values with no floating-point drift.

## Install

```ruby
# Gemfile
gem "stern", git: "https://github.com/cassiopagnoncelli/stern.git"
```

```ruby
# config/routes.rb
mount Stern::Engine, at: "/stern"
```

### Database

Stern uses its own PostgreSQL database. Your `config/database.yml` needs a named
connection per environment:

```yaml
stern_development:
  adapter: postgresql
  database: your_app_stern_development
  # ... (same user/host/etc. as your primary)
stern_test:
  adapter: postgresql
  database: your_app_stern_test
stern_production:
  adapter: postgresql
  database: your_app_stern_production
```

### Chart selection

Choose a chart by setting `STERN_CHART` (defaults to `general`). Charts live under
`config/charts/*.yaml` inside the engine; you can add your own and point to them.

```sh
export STERN_CHART=general
```

### First-time setup

```sh
bin/setup
```

This drops the test DB, installs gems, runs migrations (including the
`create_entry` / `destroy_entry` PL/pgSQL functions from `db/functions/*.sql`), and
seeds the books defined by the active chart.

## Concepts

| Concept | What it is |
|---|---|
| **Book** | An accounting account (e.g. `merchant_balance`). Identified by a 31-bit integer code derived from its name. |
| **Entry** | A single signed amount written to a `(book, gid)` pair at a timestamp. Immutable; carries the running `ending_balance`. |
| **EntryPair** | A balanced pair of entries (amount + / amount -). The atomic unit of a transaction. |
| **Operation** | A high-level, idempotent action recorded in `stern_operations`. Produces one or more EntryPairs. |
| **ScheduledOperation** | An operation queued for future execution via a background job. |
| **gid** | "Group id" — the *cause* an entry is keyed by. See [The `gid` parameter](#the-gid-parameter). |

## The `gid` parameter

Every entry is written at a `(book_id, gid, currency)` tuple. The `gid`
("group id") is **the cause of the entry, not the owner of the balance**.
Both legs of an `EntryPair.add_<pair>(uid, gid, …)` land at the single gid
the caller passes — that gid identifies *what the entry is for* (a specific
payment, withdrawal, refund, …), not necessarily the stakeholder whose
balance moves.

### Worked example: `ChargePaymentFee`

When a payment fee is debited from a merchant, both legs land at `gid =
payment_id`:

```ruby
# app/operations/stern/general/charge_payment_fee.rb (paraphrased)
EntryPair.add_charge_pix_fee_merchant(
  merchant_id,   # uid — joins the entry pair to its cause
  payment_id,    # gid — the cause these entries are keyed by
  amount, currency, operation_id:,
)
# => Entry(book: merchant_available,  gid: payment_id, amount: -fee)
# => Entry(book: payment_fee_pix,     gid: payment_id, amount: +fee)
```

The same `merchant_available` book also carries entries written at `gid =
merchant_id` (deposits, credit applications, transfers) and at other causes
(withdrawal locks, refund locks). Each subset captures one cause's
contribution to the merchant's available balance.

`target_tuples` is independent of where entries land. `ChargePaymentFee`
returns `(merchant_available, merchant_id, currency)` plus
`(payment_fee_pix, payment_id, currency)`, so two fee charges on the **same**
merchant serialize while charges on different merchants run in parallel. The
lock key is the stakeholder; the entry's gid is the cause — they diverge by
design.

### Invariant: per-gid reads are partial

`Stern.balance(gid, book_id, currency)` (and `BalanceQuery`) returns only the
slice of `(book_id, currency)` written at that single gid:

```ruby
# Just the slice at gid = merchant_id (deposits, credits, transfers).
# NOT the sum of every entry that affects this merchant's availability.
Stern.balance(merchant_id, :merchant_available, :BRL)
```

The full balance of `(book_id, currency)` is the sum across every gid:

```ruby
Stern.outstanding_balance(:merchant_available, :BRL)             # book-wide total
Stern::BookBalancesQuery.new(book_id: :merchant_available,       # per-gid breakdown
                             currency: :BRL).call
```

Treat per-gid reads as **cause-scoped**, not **owner-scoped**.

## The chart

[config/charts/general.yaml](config/charts/general.yaml):

```yaml
operations: general   # which app/operations/stern/<module> is active

books:
  - merchant_balance
  - customer_balance
  - pp_charge_pix
  # ...

entry_pairs:
  split_merchant:
    book_add: merchant_withholding
    book_sub: pp_payment
  split_partner:
    book_add: partner_withholding
    book_sub: pp_payment
```

Every book automatically gets a mirrored `<book>_0` counterpart for implicit entry
pairs (where you don't need to name a distinct sub book). Every explicit `entry_pairs`
entry declares the `book_add` / `book_sub` pair directly.

At boot, the chart is parsed into `Stern.chart` (a frozen value object):

```ruby
Stern.chart.books                       # Hash{Symbol => Chart::Book}
Stern.chart.book(:merchant_balance)     # => #<Book name=..., code=...>
Stern.chart.entry_pair(:split_merchant) # => #<EntryPair name=..., book_add=..., book_sub=...>
```

## Usage

### Run an operation

```ruby
op = Stern::ChargePix.new(
  charge_id: 1001,
  merchant_id: 1101,
  customer_id: 2001,
  amount: 9900,        # cents
  currency: "brl",
)
operation_id = op.call(idem_key: "charge-1001-unique")
```

`idem_key` makes the call replay-safe: calling again with the same key and identical
params returns the existing `operation_id`; calling with the same key but different
params raises `Stern::IdempotencyConflict`. Keys must be 8–24 characters (the column
is `limit: 24` to keep the unique B-tree index compact, so UUIDs/ULIDs won't fit —
use a shorter scheme). The exception carries the conflicting
state for translation into a 409-style response or a telemetry breadcrumb:

```ruby
begin
  op.call(idem_key: key)
rescue Stern::IdempotencyConflict => e
  e.idem_key                # the key that collided
  e.existing_operation_id   # id of the previously-recorded Operation
  e.expected_params         # params the recorded Operation was called with
  e.actual_params           # params the current call attempted
end
```

The same exception surfaces from the race-loser path when two concurrent callers
hit the unique index with mismatched params, so a single rescue covers both
detection windows.

### Query a balance

```ruby
Stern.balance(1101, :merchant_balance, :BRL)
# => 9900 (cents, at current time)

Stern.balance(1101, :merchant_balance, :BRL, 1.day.ago)
# => 0

Stern.outstanding_balance(:merchant_balance, :BRL)
# => sum of balances across every gid in the book
```

Lower-level query objects are available for more complex reports:

```ruby
Stern::BalanceSheetQuery.new(
  start_date: 7.days.ago,
  end_date:   Time.current,
  currency:   :BRL,
  book_ids:   [:merchant_balance, :customer_balance],
).call
```

### Currencies

```ruby
Stern.cur("USD")  # => 811 (indexed integer)
Stern.cur(811)    # => "USD"
Stern.currencies.code(:BRL)  # => 821
```

The catalog lives in [config/currencies_catalog.yaml](config/currencies_catalog.yaml).

## Writing a custom operation

```ruby
# app/operations/stern/general/adjust_balance.rb
module Stern
  class AdjustBalance < BaseOperation
    include ActiveModel::Validations

    inputs :merchant_id, :amount, :currency

    validates :merchant_id, presence: true, numericality: { other_than: 0 }
    validates :amount, presence: true
    validates :currency, presence: true

    # Declares which (book, gid, currency) tuples this op reads or writes.
    # BaseOperation#call acquires a per-tuple advisory lock before perform
    # runs, so concurrent ops on the same tuple serialize cleanly.
    def target_tuples
      tuples_for_pair(:merchant_balance, merchant_id, merchant_id, currency)
    end

    def perform(operation_id)
      raise ArgumentError if invalid?
      EntryPair.add_merchant_balance(
        SecureRandom.random_number(1 << 30),
        merchant_id, amount, currency, operation_id:,
      )
    end
  end
end
```

`BaseOperation#call` wraps `perform` in a transaction with per-tuple advisory
locks (from `target_tuples`) and records an `Operation` row with the serialized
inputs for audit. The `inputs` DSL generates attr accessors and drives the
params hash — no scraping of stray instance variables, no custom `initialize`.
`currency` is auto-normalized from its string name to its integer code before
`target_tuples` or `perform` runs.

### Checklist

When adding an operation:

1. **Declare `inputs`** — every kwarg you accept. Drives the audit-log params
   hash. Use `validates_exactly_one_of` for stakeholder-pick ops.
2. **Pick the entry's `gid` deliberately** — see [The `gid` parameter](#the-gid-parameter).
   Choose the cause you want to slice the book by later: payment id for
   per-payment fees, withdrawal id for per-withdrawal accounting, stakeholder
   id when the cause *is* the stakeholder (deposits, transfers, credits).
   Different ops on the same book may choose different gid kinds — that's
   intentional, not a smell.
3. **Declare `target_tuples`** — every `(book, gid, currency)` the op reads
   or writes, typically via `tuples_for_pair(pair_name, book_sub_gid,
   book_add_gid, currency)`. The two lock gids may differ from each other
   *and* from the gid the entries are written at; they're the lock
   granularity, not the entry key. Declaring extras is harmless; declaring
   too few is a correctness bug.
4. **Implement `perform(operation_id)`** — runs inside a transaction with
   advisory locks already held. Use `EntryPair.add_<pair>(uid, gid, …)` for
   ledger writes; use `runtime_check` for state-dependent preconditions
   (e.g. balance pre-checks via `require_sufficient_balance!`).
5. **Add a concurrency spec** if `perform` reads-then-writes — see
   [AGENTS.md](AGENTS.md#testing-a-new-operation).

See [AGENTS.md](AGENTS.md) for the full operation-writing contract.

## Scheduled operations

Queue an operation for later:

```ruby
Stern::ScheduledOperation.build(
  name: "ChargePix",
  params: { charge_id: 1, merchant_id: 1101, customer_id: 2, amount: 9900, currency: "usd" },
  after_time: 1.hour.from_now,  # or a fixed Time, e.g. Time.utc(2026, 5, 1, 9, 0)
).save!
```

A background job polls the queue via [`Stern::ScheduledOperationService`](app/services/stern/scheduled_operation_service.rb):

```ruby
# inside your worker (e.g. Sidekiq periodic job)
Stern::ScheduledOperationService.enqueue_list.each do |sop_id|
  YourJob.perform_later(sop_id)
end
```

Each `YourJob` then calls `Stern::ScheduledOperationService.process_sop(sop_id)` which
instantiates the operation and runs it with the stored params.

## Health checks

Audits (read-only, safe to call anywhere):

```ruby
Stern::Doctor.amount_consistent?                                       # sum(all amounts) == 0
Stern::Doctor.amount_inconsistency                                     # nil, or { sum: <non-zero> }
Stern::Doctor.ending_balance_consistent?(book_id:, gid:, currency:)    # ledger cascade is intact
Stern::Doctor.first_ending_balance_inconsistency(book_id:, gid:, currency:)
                                                                       # nil, or detail of the first bad row
Stern::Doctor.ending_balances_inconsistencies(book_id:, gid:, currency:) # => [entry_id, ...]
Stern::Doctor.first_inconsistency                                      # nil, or tagged detail of the first
                                                                       # broken invariant across the whole ledger
```

The `_inconsistency` / `first_*` companions return `nil` on success and a
detail hash on failure, so a `?` predicate can be used on hot paths and the
detail surfaced only when a spec or log line needs it.

Repairs (destructive, never in production unless you're certain):

```ruby
Stern::Repair.rebuild_book_gid_balance(book_id, gid, currency)
Stern::Repair.rebuild_gid_balance(gid, currency)   # every book for this gid
Stern::Repair.rebuild_balances(confirm: true)       # every tuple in the ledger
Stern::Repair.clear(confirm: true)                  # wipes the ledger; non-production only
```

## Running the scheduled-operation worker

Stern ships a worker loop — host apps don't need to reinvent one:

```sh
bundle exec rake stern:worker:start
```

Configurable via environment variables (defaults shown):

```sh
STERN_WORKER_CONCURRENCY=1            # threads in the processing pool
STERN_POLL_INTERVAL=5                 # seconds between polls for ready SOPs
STERN_JANITOR_INTERVAL=60             # seconds between clear_picked/clear_in_progress runs
STERN_IN_PROGRESS_TIMEOUT_SECONDS=600 # seconds before clear_in_progress recycles a stuck :in_progress SOP
```

Bump `STERN_IN_PROGRESS_TIMEOUT_SECONDS` past your longest expected op
runtime when host apps run legitimately slow ops (external API calls,
large repairs) — otherwise the janitor will treat them as crashed and
retry them. The same value is also settable in Ruby:

```ruby
# config/initializers/stern.rb
Stern.in_progress_timeout_seconds = 1800
```

Explicit assignment takes precedence over the env var.

Embedding programmatically (e.g. inside another long-running process):

```ruby
Stern::Workers::Runner.new(
  concurrency: 4,
  install_signal_handlers: false,  # if the host owns SIGTERM handling
).start
```

`Runner#start` blocks until the process receives SIGTERM/SIGINT or
`Runner#stop` is called. In-flight SOPs are allowed to finish within
`SHUTDOWN_TIMEOUT` (30s, hard bound — not 2×). If the pool fails to
terminate gracefully within that budget (e.g. a SOP blocked on a hung
external call with no timeout), the runner force-kills it so the
process can exit before k8s SIGKILL takes over. TERM/INT handlers the
runner installs are restored on exit, so embedded hosts aren't left
with stale closures pointing at a dead instance.

**Low-latency pickup via Postgres LISTEN/NOTIFY.** The runner also listens
on a dedicated connection for `NOTIFY`s fired by `stern_sop_notify_trigger`
whenever a SOP enters `pending`. On notify, the runner's main loop wakes
immediately — so freshly-scheduled work gets picked up in milliseconds
regardless of `STERN_POLL_INTERVAL`. This lets you set `poll_interval` high
(e.g. 30s) for cheap idle load while still reacting near-instantly to new
arrivals. The listen thread reconnects automatically with capped exponential
backoff (up to 30s) if its connection drops — transient blips don't kill
low-latency pickup. The listen socket also has TCP keepalive enabled
(~60s dead-connection detection) so silent NAT/firewall drops are caught
without waiting for the OS default ~2-hour idle timeout.

**PgBouncer note.** If the host app routes through PgBouncer in
`pool_mode = transaction` or `statement`, LISTEN can't work — the session
state that LISTEN registers is discarded at the next checkout. Opt out with
`listen_for_notifications: false`; the runner falls back to polling alone
(still correct, just less responsive). Session-mode PgBouncer is fine.

## Pruning operation attempts

`Stern::OperationAttempt` is an append-only audit log: every
`BaseOperation#call` invocation writes one row, including the failed retries
that pile up under a flapping external API.

**Default behavior.** `Stern::Workers::Runner` runs an in-process prune once
an hour (`STERN_PRUNE_INTERVAL=3600`), bounded to
`STERN_PRUNE_MAX_BATCHES=10` batches per status per tick. An installation
that does nothing else still won't accumulate attempt rows forever. To
disable when you'd rather drive prunes from cron, set `STERN_PRUNE_INTERVAL=0`.

Run from cron / a k8s CronJob (typically once a day, off-peak) — unbounded
sweep, recommended when retention windows are long and you want a single
clean log line per cycle:

```sh
bundle exec rake stern:operation_attempts:prune
```

Per-status retention windows (defaults shown):

```sh
STERN_PRUNE_SUCCESS_DAYS=14   # successful attempts (op survived; the row is duplicative of stern_operations)
STERN_PRUNE_FAILED_DAYS=90    # failed attempts (the only forensic trail for a rolled-back op)
STERN_PRUNE_PENDING_DAYS=7    # stale `pending` rows — itself a bug signal, but reaped to bound the table
STERN_PRUNE_BATCH_SIZE=1000   # rows deleted per statement
STERN_PRUNE_SLEEP=0.1         # seconds between batches; raise for gentler throughput on a large backlog
```

The first run on an installation that has been retrying for months may
delete millions of rows. The worker's bounded sweep handles this
automatically — the residual is split across many ticks and the table
drains over hours, never blocking shutdown. If you'd rather clear the
backlog in one pass via the rake task, use a smaller batch size and a
longer sleep (`STERN_PRUNE_BATCH_SIZE=500 STERN_PRUNE_SLEEP=0.5`), and
consider a manual `VACUUM (ANALYZE) stern_operation_attempts`
afterwards — autovacuum will catch up on its own, but a manual run
reclaims pages immediately.

The admin attempts view surfaces the configured retention at the top of
the page so an empty result past the cutoff isn't misread as "nothing
happened."

To override the worker's auto-prune cadence (e.g. once a day instead of
hourly):

```sh
STERN_PRUNE_INTERVAL=86400 bundle exec rake stern:worker:start
```

To disable it entirely (rake-from-cron is the source of truth):

```sh
STERN_PRUNE_INTERVAL=0 bundle exec rake stern:worker:start
```

## Metrics (Prometheus)

Stern exposes a Prometheus registry populated from `ActiveSupport::Notifications`
events the scheduled-operation pipeline emits:

- `stern_sop_picked_total` — counter, SOPs picked from the pending queue
- `stern_sop_terminal_total{outcome, op_name}` — counter, SOPs reaching a
  terminal state (`finished` / `argument_error` / `runtime_error`)
- `stern_sop_process_duration_seconds{outcome, op_name}` — histogram,
  `process_operation` wall-clock per attempt
- `stern_sop_pickup_lag_seconds` — histogram, seconds between `after_time` and
  the actual pick
- `stern_sop_count{status}` — gauge, queue depth by status (refresh-on-demand)
- `stern_operation_attempts_count{status}` — gauge, current row count of
  `stern_operation_attempts` by status (`success` / `failed` / `pending`).
  Pair with the worker auto-prune to confirm prune throughput is keeping up
  with insert rate; sustained growth means raising `STERN_PRUNE_MAX_BATCHES`
  or shortening `STERN_PRUNE_INTERVAL` (refresh-on-demand)

Scrape from a host-app controller:

```ruby
# app/controllers/prometheus_controller.rb
class PrometheusController < ActionController::Base
  def index
    Stern::Metrics.refresh_queue_gauges!
    render plain: Prometheus::Client::Formats::Text.marshal(Stern::Metrics.registry)
  end
end
```

`refresh_queue_gauges!` runs two `GROUP BY status` queries — one against
`stern_scheduled_operations`, one against `stern_operation_attempts` — to
populate the snapshot gauges; the counters/histograms update automatically
as events fire.

## Console tips

```ruby
Stern::Entry.all.pp                 # pretty-prints every row with ANSI colors
Stern::Operation.last.pp
Stern.chart.books.keys.size
Stern::Operation.list               # available operation classes for the active chart
```

The `.pp` extension is installed on `Array` and `ActiveRecord::Relation` only inside
`rails console` — web and test paths never see it.

## Testing

```sh
bundle exec rspec
bundle exec rubocop
```

The suite is fully green and uses transactional fixtures. `spec/dummy/` is a minimal
Rails host for engine tests.

## License

Commercial — requires written authorization from the author for any use.
