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
| `Stern::ScheduledOperationService.enqueue_list` | returns SOP ids ready to pick (and flips them to `:picked`) | host app's picker job |
| `Stern::ScheduledOperationService.process_sop(id)` | runs one SOP end-to-end, updates its status | host app's consumer |
| `Stern::ScheduledOperationService.clear_picked` | resets SOPs stuck in `:picked` for > 300s back to `:pending` | host app's janitor job |

Stern has no dependency on `sidekiq`, `sidekiq-cron`, or `bunny` — those are
host-app choices. The integration can be swapped for any equivalent stack
(ActiveJob + solid_queue, cron + `rails runner`, SQS + ECS, etc.); the three
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

Resets SOPs stuck in `:picked` past `QUEUE_ITEM_TIMEOUT_IN_SECONDS` (300s)
back to `:pending` so they reappear on the next pick.

```ruby
# your_app/app/jobs/sop_janitor_job.rb
class SopJanitorJob
  include Sidekiq::Job
  sidekiq_options queue: :stern_picker, retry: 3

  def perform
    Stern::ScheduledOperationService.clear_picked
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

## Known race: double-picking inside `enqueue_list`

Two pickers ticking in parallel can both read the same pending rows and both
`UPDATE status = :picked` before the other commits. Each publishes the same
id, and two consumers run `process_sop` on it — two Operation rows, two
EntryPair sets.

Called out in [TODO.md](../TODO.md); **not fixed at the time of writing**.
Two complementary fixes:

1. **Exclusive pick in the same statement.** Change [`enqueue_list`](../app/services/stern/scheduled_operation_service.rb:30)
   to use `SELECT ... FOR UPDATE SKIP LOCKED` so concurrent pickers partition
   the pending set.

2. **Idempotency at the write.** Propagate an `idem_key` (e.g.
   `"sop-#{sop.id}"`) into `op.call` inside `process_sop`. Even if a duplicate
   slips past RabbitMQ or the picker, only the first write commits —
   `BaseOperation#find_existing_operation` already short-circuits matching
   keys ([app/operations/stern/base_operation.rb:172](../app/operations/stern/base_operation.rb:172)).

Until (1) ships, rely on (2) plus ack-after-commit for safety. A duplicate
publish then yields one committed Operation and one redundant `:finished`
update; no ledger corruption.

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
