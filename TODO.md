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

## Test safety net

- Structural integrity invariants not yet verified after every stress run:
  - Every EntryPair has exactly 2 Entry rows that sum to 0 ("S").
  - Every Operation row has ≥ 1 associated EntryPair, every EntryPair has a
    valid operation, and per-op params match the written (gid, currency) ("T").
  - Pattern: add `assert_entry_pairs_structurally_sound!` and
    `assert_operations_integral!` to spec/support/, call from every stress
    test in balance_invariant_spec.rb and locking_matrix_spec.rb.
