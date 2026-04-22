# Integrating Scheduled Operations with RabbitMQ + Sidekiq

This guide shows how to run `Stern::ScheduledOperationService` (SOPs) durably
under an at-least-once pipeline backed by RabbitMQ for queuing and Sidekiq for
periodic polling. Stern itself is driver-agnostic — [the service](../app/services/stern/scheduled_operation_service.rb)
exposes pure methods (`enqueue_list`, `process_sop`, `clear_picked`), so any
scheduler with at-least-once delivery works. This doc is the concrete recipe
for the RabbitMQ + Sidekiq combination called out in [TODO.md](../TODO.md).

## Topology

```
                ┌──────────────────────────────┐
                │  Sidekiq periodic (cron)     │
                │  - enqueue_list tick (10s)   │
                │  - clear_picked tick (60s)   │
                └──────────────┬───────────────┘
                               │ publish SOP ids
                               ▼
                     ┌──────────────────┐
                     │  RabbitMQ queue  │
                     │   stern.sops     │
                     └────────┬─────────┘
                              │ ack / nack
                              ▼
                 ┌────────────────────────────┐
                 │  Bunny consumer pool       │
                 │  process_sop(id) per msg   │
                 └────────────────────────────┘
```

Sidekiq owns *when* work gets picked and stuck-pick recovery. RabbitMQ owns
delivery guarantees — messages stay on the queue until a consumer acks, and
are redelivered on crash/nack. Workers can be a separate process fleet in any
language; they only need DB access.

## Gemfile

```ruby
gem "sidekiq"
gem "sidekiq-cron"   # or any periodic scheduler you already use
gem "bunny"          # RabbitMQ client
```

`bundle install`, then boot Sidekiq alongside the Rails app the way you
normally would (`bundle exec sidekiq`).

## Sidekiq: periodic picker

Pulls pickable SOPs from the ledger DB and publishes their ids onto
RabbitMQ. `enqueue_list` flips each picked SOP to `:picked` so it won't be
re-picked by the next tick — but see **Known race** below.

```ruby
# app/jobs/stern/sop_picker_job.rb
module Stern
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
end
```

Schedule with `sidekiq-cron`:

```yaml
# config/sidekiq_cron.yml
stern_sop_picker:
  cron: "*/10 * * * * *"     # every 10 seconds
  class: "Stern::SopPickerJob"

stern_sop_janitor:
  cron: "0 * * * * *"         # every minute
  class: "Stern::SopJanitorJob"
```

## Sidekiq: stuck-pick janitor

Resets SOPs stuck in `:picked` past `QUEUE_ITEM_TIMEOUT_IN_SECONDS` (300s by
default) back to `:pending` so they reappear in the next pick.

```ruby
# app/jobs/stern/sop_janitor_job.rb
module Stern
  class SopJanitorJob
    include Sidekiq::Job
    sidekiq_options queue: :stern_picker, retry: 3

    def perform
      Stern::ScheduledOperationService.clear_picked
    end
  end
end
```

## RabbitMQ consumer: process each SOP

A separate process — can be a thin Rake task or a Sidekiq-hosted worker loop;
the key property is that it acks only after `process_sop` commits.

```ruby
# bin/stern_sop_consumer
require_relative "../config/environment"

conn = Bunny.new(ENV.fetch("RABBITMQ_URL")).tap(&:start)
ch   = conn.create_channel
ch.prefetch(16)                                    # back-pressure
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
    ch.nack(delivery_info.delivery_tag, false, true)   # redeliver
  end
end
```

`process_sop` itself already records the terminal status (`:finished`,
`:argument_error`, `:runtime_error`) on the SOP row inside its own transaction
— the only thing the consumer has to get right is **ack after commit**. The
`rescue` block above gives you that: any unexpected exception nacks with
redelivery, so the message survives a worker crash.

Run several of these in parallel across machines — RabbitMQ's round-robin
delivery distributes the load; `prefetch` prevents any one consumer from
hogging the queue.

## Known race: double-picking inside `enqueue_list`

Two pickers ticking in parallel can both read the same pending rows and both
`UPDATE status = :picked` before the other commits. Each publishes the same
id, and two consumers run `process_sop` on the same SOP — two Operation rows,
two EntryPair sets.

This is called out in [TODO.md](../TODO.md) and is **not fixed at the time of
writing**. Two complementary fixes:

1. **Exclusive pick in the same statement.** Change `enqueue_list` to use
   `SELECT ... FOR UPDATE SKIP LOCKED` so concurrent pickers partition the
   pending set. See [`ScheduledOperationService#enqueue_list`](../app/services/stern/scheduled_operation_service.rb:30).

2. **Idempotency at the write.** Propagate an `idem_key` (e.g.
   `"sop-#{sop.id}"`) into `op.call` inside `process_sop`. Even if double
   delivery slips past RabbitMQ or the picker, only the first write commits —
   `BaseOperation#find_existing_operation` already short-circuits matching
   keys.

Until (1) ships, rely on (2) plus the consumer's ack-after-commit for safety.
A duplicate publish will result in one committed Operation and one redundant
`:finished` status update; no ledger corruption.

## Verification

1. `Stern::ScheduledOperation.build(name: "...", params: {...}, after_time: 10.seconds.from_now).save!`
2. Watch the Sidekiq dashboard (`Sidekiq::Web`): the picker job should fire
   every 10s.
3. Watch the RabbitMQ management UI: the `stern.sops` queue should receive
   the id and a consumer should drain it within seconds.
4. `Stern::ScheduledOperation.find(id).status` should transition
   `pending → picked → in_progress → finished`.
5. Kill a consumer mid-`process_sop`: after reconnect, RabbitMQ redelivers;
   the SOP either lands `:finished` (if the Rails transaction committed) or
   gets re-attempted.

## References

- Service surface: [app/services/stern/scheduled_operation_service.rb](../app/services/stern/scheduled_operation_service.rb)
- SOP model + statuses: [app/models/stern/scheduled_operation.rb](../app/models/stern/scheduled_operation.rb)
- Operation idempotency (`idem_key`): [app/operations/stern/base_operation.rb](../app/operations/stern/base_operation.rb)
- Open durability work: [TODO.md](../TODO.md)
