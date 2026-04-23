# Integrating Scheduled Operations with RabbitMQ + Sidekiq

This guide shows how a **host app** that mounts the Stern engine can run
`Stern::ScheduledOperationService` (SOPs) durably under an at-least-once
pipeline backed by RabbitMQ for queuing and Sidekiq for periodic polling.

## Where this code lives

Stern is an [isolated-namespace Rails engine](../lib/stern/engine.rb); it
doesn't ship a scheduler. Everything in this guide — gem dependencies, jobs,
consumer process, cron config — **belongs in your host app**, not in the
engine. Stern only exposes the service API:

| Method | Purpose | Where it's called |
| --- | --- | --- |
| `Stern::ScheduledOperationService.enqueue_list` | reserves due SOPs with `SELECT ... FOR UPDATE SKIP LOCKED`, flips them to `:picked`, returns their ids | host app's picker job |
| `Stern::ScheduledOperationService.process_sop(id)` | runs one SOP end-to-end; op-level errors land the SOP in `:pending`-with-backoff (retryable) or `:argument_error` / `:runtime_error` (terminal) | host app's consumer |
| `Stern::ScheduledOperationService.clear_picked` | resets SOPs stuck in `:picked` for > 300s back to `:pending` | host app's janitor job |
| `Stern::ScheduledOperationService.clear_in_progress` | recycles SOPs stuck in `:in_progress` for > 600s (consumer crashed mid-op); bumps `retry_count` and backs off, or terminally marks `:runtime_error` past the op class's `retry_policy[:max_retries]` (default 5) | host app's janitor job |

Stern has no dependency on `sidekiq`, `sidekiq-cron`, or `bunny` — those are
host-app choices. The integration can be swapped for any equivalent stack
(ActiveJob + solid_queue, cron + `rails runner`, SQS + ECS, etc.); the four
methods above are the only contract.

Service source: [app/services/stern/scheduled_operation_service.rb](../app/services/stern/scheduled_operation_service.rb).

## Topology

```
 ┌───────────────────────────────┐
 │  Host app — Sidekiq process   │
 │  Periodic (sidekiq-cron):     │
 │   - SopPickerJob every 10s    │──┐ publish ids
 │   - SopJanitorJob every 60s   │  │
 └───────────────────────────────┘  │
                                    ▼
                         ┌─────────────────────┐
                         │  RabbitMQ: stern.sops│
                         │  (durable queue)    │
                         └──────────┬──────────┘
                                    │ deliver; ack on commit
                                    ▼
                 ┌───────────────────────────────────┐
                 │  Host app — Bunny consumer fleet  │
                 │  process_sop(id) per message      │
                 └───────────────────────────────────┘
```

Sidekiq owns *when* polling runs and stuck-pick recovery. RabbitMQ owns
delivery guarantees — messages stay on the queue until a consumer acks, and
redeliver on crash/nack. Consumers can be any process with DB access: a Rake
task, a dedicated binary, another Ruby service, or a non-Ruby worker.

## Host-app Gemfile

```ruby
# your_app/Gemfile
gem "stern", git: "https://github.com/cassiopagnoncelli/stern.git"
gem "sidekiq"
gem "sidekiq-cron"
gem "bunny"
```

Run Sidekiq the usual way: `bundle exec sidekiq` alongside your Rails server.

## Host-app picker job

Lives in the host app's own namespace (use whatever module layout your app
prefers — Stern doesn't care). The job reads the ledger, publishes ids to
RabbitMQ, and exits. Its Sidekiq retry handles transient DB/MQ blips; the
next cron tick picks up anything it missed.

```ruby
# your_app/app/jobs/sop_picker_job.rb
class SopPickerJob
  include Sidekiq::Job
  sidekiq_options queue: :stern_picker, retry: 3

  def perform
    ids = Stern::ScheduledOperationService.enqueue_list
    return if ids.empty?

    Rabbit.with_channel do |ch|
      queue = ch.queue("stern.sops", durable: true)
      ids.each do |id|
        queue.publish(id.to_s, persistent: true, message_id: "sop-#{id}")
      end
    end
  end
end
```

`Rabbit.with_channel` stands in for whatever connection helper your app uses
around Bunny. A minimal one:

```ruby
# your_app/lib/rabbit.rb
module Rabbit
  def self.connection
    @connection ||= Bunny.new(ENV.fetch("RABBITMQ_URL")).tap(&:start)
  end

  def self.with_channel
    ch = connection.create_channel
    yield ch
  ensure
    ch&.close
  end
end
```

## Host-app janitor job

Runs two recoveries. `clear_picked` resets SOPs stuck in `:picked` past
`QUEUE_ITEM_TIMEOUT_IN_SECONDS` (300s) — published to RabbitMQ but never
acked by a consumer, so safe to re-publish. `clear_in_progress` handles
SOPs stuck in `:in_progress` past `IN_PROGRESS_TIMEOUT_IN_SECONDS` (600s) —
a consumer started the op and then died (OOM, SIGKILL, pod eviction). The
crash counts as a failed attempt, so `retry_count` bumps and the SOP goes
back to `:pending` with the same backoff the `StandardError` rescue uses
(see the op class's `retry_policy`); past `retry_policy[:max_retries]` it
settles in `:runtime_error`.

```ruby
# your_app/app/jobs/sop_janitor_job.rb
class SopJanitorJob
  include Sidekiq::Job
  sidekiq_options queue: :stern_picker, retry: 3

  def perform
    Stern::ScheduledOperationService.clear_picked
    Stern::ScheduledOperationService.clear_in_progress
  end
end
```

## Host-app cron schedule

```yaml
# your_app/config/sidekiq_cron.yml
stern_sop_picker:
  cron: "*/10 * * * * *"     # every 10 seconds
  class: "SopPickerJob"

stern_sop_janitor:
  cron: "0 * * * * *"         # every minute
  class: "SopJanitorJob"
```

Load it at boot from `your_app/config/initializers/sidekiq.rb`:

```ruby
Sidekiq.configure_server do |_|
  schedule = YAML.load_file(Rails.root.join("config/sidekiq_cron.yml"))
  Sidekiq::Cron::Job.load_from_hash(schedule)
end
```

## Host-app consumer process

A separate OS process — boot the Rails env, subscribe to the queue, ack only
after `process_sop` commits.

```ruby
# your_app/bin/stern_sop_consumer
#!/usr/bin/env ruby
require_relative "../config/environment"

conn = Bunny.new(ENV.fetch("RABBITMQ_URL")).tap(&:start)
ch   = conn.create_channel
ch.prefetch(16)   # back-pressure: no worker hogs the queue
queue = ch.queue("stern.sops", durable: true)

queue.subscribe(manual_ack: true, block: true) do |delivery_info, _props, body|
  sop_id = Integer(body)
  begin
    Stern::ScheduledOperationService.process_sop(sop_id)
    ch.ack(delivery_info.delivery_tag)
  rescue Stern::CannotProcessNonPickedSopError, Stern::CannotProcessAheadOfTimeError
    # SOP state changed since publish — drop, don't redeliver.
    ch.ack(delivery_info.delivery_tag)
  rescue => e
    Rails.logger.error("SOP #{sop_id} failed: #{e.class} #{e.message}")
    ch.nack(delivery_info.delivery_tag, false, true)  # redeliver
  end
end
```

Boot as many of these as you need behind your process manager (systemd,
Foreman, Kubernetes Deployment). RabbitMQ round-robins deliveries across
them; `prefetch` keeps one consumer from starving the others.

`process_sop` commits the SOP's terminal status (`:finished`,
`:argument_error`, `:runtime_error`) in its own transaction. The consumer's
only job is **ack after that commit** — the `rescue` block above gives you
exactly that, so an OS-level kill redelivers the message.

### Two layers of retry

Business-level errors never reach the consumer's generic `rescue => e`
branch. `process_operation` catches them internally: `ArgumentError` lands
the SOP terminally in `:argument_error`; `StandardError` pushes it back to
`:pending` using the op class's declared `retry_policy` (default:
exponential backoff with base 30s — 30s, 60s, 2m, 4m, 8m — and
`max_retries: 5`) and increments `retry_count`. Past `max_retries` it
settles in `:runtime_error`, where it can be revived with
`rake stern:sop:rescue[id]`. The next picker tick re-publishes; redelivery
is idempotent via the propagated `idem_key` (see "Picker hardening" below).

The consumer's `nack`-and-redeliver path therefore fires only for
infrastructure failures — OS kill, DB connection loss, network blips
between Stern and Postgres. RabbitMQ's redeliver + `ack-after-commit` gives
the guarantee there; Stern's own retry loop gives it for op-level
transient failures. The two layers don't churn each other: op errors stay
in Stern, infra errors stay in RabbitMQ.

## Picker hardening

Two pickers ticking in parallel would otherwise both read the same pending
rows and both `UPDATE status = :picked` before either commits, publishing
the same id twice and running `process_sop` twice — two Operation rows,
two EntryPair sets.

Two fixes are in place, complementary:

1. **Exclusive pick in the same statement.** [`enqueue_list`](../app/services/stern/scheduled_operation_service.rb:39)
   reserves ids inside a transaction with `SELECT ... FOR UPDATE SKIP
   LOCKED`, so concurrent pickers partition the pending set — worker B's
   SELECT skips rows worker A already locked.

2. **Idempotency at the write.** [`process_sop`](../app/services/stern/scheduled_operation_service.rb:67)
   passes a stable `idem_key` (`"sop-<zero-padded-id>"`) into
   `BaseOperation#call`. Any repeat `process_sop` on the same SOP
   short-circuits via
   [`find_existing_operation`](../app/operations/stern/base_operation.rb:172);
   the race between two concurrent callers that both pass that check is
   resolved by a partial unique index on `idem_key` + a `RecordNotUnique`
   rescue in [`BaseOperation#call`](../app/operations/stern/base_operation.rb:71)
   that returns the winner's id.

Belt-and-braces: (1) prevents the double-publish at the picker, and (2)
keeps a duplicate benign even if it slips through RabbitMQ redelivery or a
`clear_picked`-then-re-pick flow.

## Verification from the host app

1. `Stern::ScheduledOperation.build(name: "...", params: {...}, after_time: 10.seconds.from_now).save!`
2. Watch `Sidekiq::Web`: `SopPickerJob` fires every 10s.
3. Watch the RabbitMQ management UI: `stern.sops` receives the id and a
   consumer drains it within seconds.
4. `Stern::ScheduledOperation.find(id).status` transitions `pending → picked
   → in_progress → finished`.
5. `kill -9` a consumer mid-`process_sop`: on reconnect, RabbitMQ redelivers;
   the SOP either lands `:finished` (if its Rails transaction committed) or
   runs again.

## References

- Service surface (Stern, stable): [app/services/stern/scheduled_operation_service.rb](../app/services/stern/scheduled_operation_service.rb)
- SOP model + statuses (Stern): [app/models/stern/scheduled_operation.rb](../app/models/stern/scheduled_operation.rb)
- Operation idempotency (`idem_key`, Stern): [app/operations/stern/base_operation.rb](../app/operations/stern/base_operation.rb)
- Open durability work: [TODO.md](../TODO.md)
