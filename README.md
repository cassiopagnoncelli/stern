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
| **gid** | "Group id" — the account/entity an entry belongs to (e.g. merchant id). |

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
params raises.

### Query a balance

```ruby
Stern.balance(1101, :merchant_balance)
# => 9900 (cents, at current time)

Stern.balance(1101, :merchant_balance, 1.day.ago)
# => 0

Stern.outstanding_balance(:merchant_balance)
# => sum of balances across every gid in the book
```

Lower-level query objects are available for more complex reports:

```ruby
Stern::BalanceSheetQuery.new(
  start_date: 7.days.ago,
  end_date:   Time.current,
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
      tuples_for_pair(:merchant_balance, merchant_id, currency)
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

See [AGENTS.md](AGENTS.md) for the full operation-writing contract.

## Scheduled operations

Queue an operation for later:

```ruby
Stern::ScheduledOperation.build(
  name: "ChargePix",
  params: { charge_id: 1, merchant_id: 1101, customer_id: 2, amount: 9900, currency: "usd" },
  after_time: 1.hour.from_now,
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
Stern::Doctor.consistent?                                    # sum(all amounts) == 0
Stern::Doctor.ending_balance_consistent?(book_id:, gid:)     # ledger cascade is intact
Stern::Doctor.ending_balances_inconsistencies(book_id:, gid:) # => [entry_id, ...]
```

Repairs (destructive, never in production unless you're certain):

```ruby
Stern::Repair.rebuild_book_gid_balance(book_id, gid)
Stern::Repair.rebuild_balances(confirm: true)
Stern::Repair.clear   # wipes the ledger; non-production only
```

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
