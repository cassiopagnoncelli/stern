# Tasks

- [s] Benchmark
- [D] Operations
- [d] Replicate frontend from CRM
- [d] SOP job must be durable, AL/E-OD, idem key; use RabbitMQ + Sidekiq
  - known bug inside the current picker: `ScheduledOperationService.enqueue_list`
    is vulnerable to a double-picking race under concurrent workers. Two workers
    can both read the same pending SOPs and both mark them `:picked`, resulting
    in double-processing (two Operation rows, two EntryPair sets).
    Minimal fix: `SELECT ... FOR UPDATE SKIP LOCKED` in the same statement.
    Broader fix: also propagate an `idem_key` into `process_sop`'s `op.call`
    so that even if double-processing happens, only one write commits.
- [s] Prometheus
