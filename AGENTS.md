# AGENTS.md — guidance for AI agents working on Stern

This file contains the conventions a coding agent (or a human) should follow when
modifying or extending the Stern engine. It is not user-facing documentation —
the README covers that.

## Review process

OpenAI Codex will review your output once you are done. Make your best.

## Writing an operation

Operations are the public API. They extend `Stern::BaseOperation`, live under
`app/operations/stern/<operations_module>/`, and follow a strict shape.

### Required elements

1. **Declare inputs with the `inputs` DSL.** Lists the kwargs the operation
   accepts. Generates attr accessors and drives the audit-log params hash —
   no scraping of stray instance variables.

2. **Declare `target_tuples`.** (Required for any operation that reads or
   writes ledger state.) Returns an array of `[book, gid, currency]` triples
   identifying every `(book_id, gid, currency)` the operation will touch —
   both reads (e.g. `Stern.balance` inside `perform`) and writes (e.g.
   `EntryPair.add_<pair>`). `BaseOperation#call` acquires a
   per-tuple Postgres advisory lock on each before `perform` runs, so:
   - concurrent ops on the **same** tuple serialize (read-decide-write is
     safe; balance invariants hold under contention);
   - concurrent ops on **disjoint** tuples run in parallel (no unnecessary
     global serialization).

3. **Implement `perform(operation_id)`.** Does the actual work. Runs inside a
   transaction with advisory locks already held. The `operation_id` is the
   persisted `Stern::Operation` row id for linking entry pairs back to the
   audit log.

### Skeleton

```ruby
module Stern
  class ChargePix < BaseOperation
    include ActiveModel::Validations

    inputs :charge_id, :merchant_id, :customer_id, :amount, :currency

    validates :charge_id, presence: true, numericality: { other_than: 0 }
    validates :merchant_id, presence: true, numericality: { other_than: 0 }
    validates :amount, presence: true
    validates :currency, presence: true, allow_blank: false, allow_nil: false

    def target_tuples
      tuples_for_pair(:pp_charge_pix, merchant_id, currency)
    end

    def perform(operation_id)
      raise ArgumentError if invalid? || operation_id.blank?
      EntryPair.add_pp_charge_pix(charge_id, merchant_id, amount, currency, operation_id:)
    end
  end
end
```

Declaring `:currency` as an input is all you need — `BaseOperation` normalizes
it from its string name to its integer code automatically, before `perform` and
`target_tuples` run. Override `normalize_inputs` only for op-specific coercion
not covered by the shared normalizer.

## The `target_tuples` contract

### What to declare

Return every `(book, gid, currency)` the operation's `perform` will **read from
or write to**. If `perform` calls `Stern.balance(gid, :merchant_balance, currency)`
and later writes to `:merchant_balance` — declare both the read and the write
tuples. (They're usually the same tuple, so one entry covers it.)

Formats accepted per triple:

- Book can be a Symbol (`:merchant_balance`), String (`"merchant_balance"`),
  or Integer book code. Symbols/Strings are resolved through `Stern.chart`.
- `gid` and `currency` must be integers. Currencies are integer codes — if
  `:currency` is declared as an input, `BaseOperation` normalizes the string
  name to its integer code before `target_tuples` is consulted.

### Helpers

For the common double-entry pattern where the operation calls
`EntryPair.add_<pair>(...)`:

```ruby
def target_tuples
  tuples_for_pair(:pp_charge_pix, merchant_id, currency)
end
```

`tuples_for_pair(pair_name, gid, currency)` looks up the named entry pair in
`Stern.chart` and returns both the `book_add` and `book_sub` tuples. Use it
whenever the operation touches exactly one entry pair.

For operations that touch multiple pairs or additional books:

```ruby
def target_tuples
  tuples_for_pair(:split_merchant, merchant_id, currency) +
    tuples_for_pair(:split_partner, partner_id, currency) +
    [[ :merchant_withholding, merchant_id, currency ]]
end
```

Order inside `target_tuples` does **not** matter — `acquire_advisory_locks`
sorts by `[book_id, gid, currency]` before acquiring, guaranteeing a consistent
order across operations and eliminating deadlock risk.

### When to opt out

The default `target_tuples → []` is correct only for operations that touch no
ledger state (rare — admin-style operations, maybe a ping). If in doubt,
declare the tuples. Declaring extras is harmless (costs one `pg_advisory_xact_lock`
call); declaring too few is a correctness bug (read-decide-write races).

### When NOT to call `target_tuples` from `perform`

`target_tuples` is evaluated by `BaseOperation#call` **before** `perform`. It
must be deterministic from the operation's declared inputs. Do not consult the
database inside `target_tuples` — any DB read needed to decide what to touch
must happen at operation construction time and be captured as an input, or the
operation must declare a superset of possible tuples.

## Testing a new operation

Include a concurrency spec if the operation has read-decide-write logic (any
`perform` that reads balance/state and conditionally writes). Pattern:

- Disable transactional fixtures: `self.use_transactional_tests = false`.
- Seed the relevant balances.
- Spawn N threads, each calling `YourOp.new(...).call`, with per-thread
  connection checkout/release.
- Assert the invariant holds: exactly the expected subset succeeds, others
  raise cleanly, and `Stern::Doctor.ending_balance_consistent?(...)` / `.amount_consistent?`
  return true.

See [spec/operations/stern/concurrency_spec.rb](spec/operations/stern/concurrency_spec.rb)
for a working template with a synthetic `WithdrawTest` op.

## Don'ts

- **Don't bypass `BaseOperation#call`.** Don't invoke `perform` directly from
  external code — advisory locks are acquired by `call`, not by `perform`.
- **Don't manipulate `Entry` or `EntryPair` directly from host apps.** The
  only supported write path is an operation calling
  `EntryPair.add_<pair_name>(...)`. Direct `Entry.create!` bypasses the
  operation-level locking and is only for engine internals.
- **Don't rely on table-level locks.** `ApplicationRecord.lock_table(table:)`
  remains available for admin/rake tools, but the standard operation flow
  does not use it. Don't reintroduce `lock_tables` in `BaseOperation#call`.
- **Don't scrape `instance_variables` for params.** `operation_params` reads
  exactly the declared `inputs`. Any `@foo = …` inside `perform` that isn't
  declared is not part of the audit log and won't match on replay.

## Related conventions

- Models are append-only via `include AppendOnly`. Updates raise
  `NotImplementedError`. Write paths on `Entry` and `EntryPair` go through
  custom `create!` / `destroy!` that delegate to PL/pgSQL functions.
- Timestamps cannot be in the future — `include NoFutureTimestamp` enforces
  it via an AR validation.
- Colorized console output uses `Stern::AnsiPrint.puts_colorized(parts)` —
  not a method on ApplicationRecord.
- Destructive maintenance ops live on `Stern::Repair`, not `Stern::Doctor`
  (which is read-only).
- Every writer on `(book, gid, currency)` acquires the same Postgres advisory
  lock via `Stern::ApplicationRecord.advisory_lock(book_id:, gid:, currency:)`.
  Three layers in place:
  1. `BaseOperation#acquire_advisory_locks` — the normal op path (via
     `target_tuples`).
  2. `create_entry` / `destroy_entry` v04 PL/pgSQL — defense-in-depth for
     direct `Entry.create!` / `Entry#destroy!` callers, and the enforcer for
     the chart-level `non_negative: true` flag (raises
     `Stern::BalanceNonNegativeViolation`, a subclass of
     `Stern::InsufficientFunds`).
  3. `Stern::Repair.rebuild_book_gid_balance` — rebuilds never race against
     in-flight ops. The higher-level helpers (`rebuild_gid_balance`,
     `rebuild_balances`) are piecewise across tuples rather than
     atomic: each per-tuple rebuild is a separate transaction with its
     own advisory lock. Between rebuilds, in-flight ops can commit; they
     produce correct cascades via layer (2), so the global ledger stays
     consistent without requiring rebuild-level atomicity. Proven under
     stress in `spec/services/stern/repair_concurrency_spec.rb`.
  All three use the same key (`hashtextextended(format('stern:%s:%s:%s',
  book_id, gid, currency))`), so the lock is reentrant across layers
  within a single transaction.
- Scheduled-operation loop is run via `Stern::Workers::Runner` — host apps
  start it with `bundle exec rake stern:worker:start`, configurable via
  `STERN_WORKER_CONCURRENCY` / `STERN_POLL_INTERVAL` / `STERN_JANITOR_INTERVAL`
  env vars. The runner owns the poll-pick-process loop, thread pool,
  graceful SIGTERM shutdown, and janitor cadence (`clear_picked` +
  `clear_in_progress`). Per-op errors stay inside the thread pool; the
  runner never dies on a single SOP failure. Shutdown is bounded by a
  single `SHUTDOWN_TIMEOUT` budget (not 2×), with `pool.kill` as fallback
  when a SOP is wedged past the grace period. Signal handlers installed
  by the runner are restored on exit, so embedded host processes aren't
  left with stale closures after shutdown.
- Low-latency pickup is driven by a Postgres trigger
  (`db/functions/sop_notify_v02.sql`) firing `NOTIFY stern_scheduled_operations_pending`
  on every status → `:pending` *transition* (INSERT, or UPDATE where
  `OLD.status IS DISTINCT FROM NEW.status`), plus a dedicated LISTEN thread
  inside the Runner that wakes the main loop on each notify. The listen
  thread auto-reconnects with capped exponential backoff and configures TCP
  keepalive (~60s dead-connection detection) to survive NAT/firewall
  half-open drops. Opt out with `Runner.new(listen_for_notifications: false, ...)`
  for PgBouncer transaction-pooled environments. The trigger depends on
  `Stern::ScheduledOperation.statuses["pending"] == 0`; a spec in
  `scheduled_operation_spec.rb` guards against enum drift.
- Scheduled-operation pipeline emits Prometheus metrics via `Stern::Metrics`.
  The service uses `ActiveSupport::Notifications.instrument` for
  `stern.sop.enqueue_list`, `stern.sop.pickup_lag`, and
  `stern.sop.process_operation`; subscribers translate events into counters
  and histograms on `Stern::Metrics.registry`. Host apps scrape by calling
  `Stern::Metrics.refresh_queue_gauges!` then rendering the registry (see
  `lib/stern/metrics.rb` for an example `/metrics` controller).
