# Stern

[![CI](https://github.com/cassiopagnoncelli/stern/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/cassiopagnoncelli/stern/actions/workflows/ci.yml)
[![Matrix](https://github.com/cassiopagnoncelli/stern/actions/workflows/matrix.yml/badge.svg?branch=main)](https://github.com/cassiopagnoncelli/stern/actions/workflows/matrix.yml)

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
  `Operation` subclasses (`ChargePayment.new(payment_method: "pix", ...).call`) which handle idempotency, locking,
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

## Usage

For the full reference — concepts, `gid` semantics, the chart, custom operations,
scheduled operations, health checks, the worker, metrics, and console tips —
see [USAGE.md](USAGE.md).

### Charge a payment

```ruby
op = Stern::ChargePayment.new(
  charge_id: 1001,
  payment_id: 2001,
  payment_method: "pix",
  amount: 9900,        # cents
  currency: "brl",
)
operation_id = op.call(idem_key: "charge-1001-unique")
```

`idem_key` makes the call replay-safe: the same key with identical params returns
the existing `operation_id`; the same key with different params raises
`Stern::IdempotencyConflict`. Keys must be 8–24 characters.
See [USAGE.md](USAGE.md#idempotency) for the full conflict-handling contract.

### Query a balance

```ruby
Stern.balance(1101, :merchant_balance, :BRL)
# => 9900 (cents, at current time)

Stern.balance(1101, :merchant_balance, :BRL, 1.day.ago)
# => 0

Stern.outstanding_balance(:merchant_balance, :BRL)
# => sum of balances across every gid in the book
```

## License

Commercial — requires written authorization from the author for any use.
