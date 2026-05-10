class AddSternForeignKeys < ActiveRecord::Migration[7.0]
  # The record graph (Entry -> EntryPair -> Operation, OperationAttempt -> Operation)
  # was previously enforced only at the application layer (BaseOperation#call,
  # EntryPair.double_entry_add, the LedgerInvariants helpers). Adding DB-level FKs
  # closes the gap against direct SQL writes and partial cleanup paths.
  #
  # on_delete semantics:
  #   - entries -> entry_pairs:  :restrict — Entry rows are append-only; no normal
  #                              path deletes a pair while entries reference it.
  #                              Repair.clear deletes Entry first, so :restrict
  #                              is compatible.
  #   - entry_pairs -> operations: :restrict — same reasoning; Repair.clear order
  #                                is Entry -> EntryPair -> Operation.
  #   - operation_attempts -> operations: :nullify — attempts can pre-exist their
  #                                       op (failed-before-commit case stores
  #                                       NULL operation_id), and `Operation`
  #                                       rows can be cleared without losing the
  #                                       post-mortem record of what was tried.
  def up
    # Pre-existing orphan cleanup. `Repair.clear` was deleting `stern_operations`
    # without touching `stern_operation_attempts`, leaving attempt rows pointing
    # at gone operations. Nullify those before installing the FK so the
    # constraint matches reality on environments that have accumulated such
    # rows. The semantic match is intentional — `:nullify` is also the
    # `on_delete` policy, so this is the same outcome the FK would produce going
    # forward. Bounded scope: only attempt rows whose operation_id has no
    # surviving operation, never any other column.
    execute(<<~SQL)
      UPDATE stern_operation_attempts a
      SET operation_id = NULL
      WHERE a.operation_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM stern_operations o WHERE o.id = a.operation_id)
    SQL

    add_foreign_key :stern_entries, :stern_entry_pairs,
                    column: :entry_pair_id, on_delete: :restrict,
                    validate: true
    add_foreign_key :stern_entry_pairs, :stern_operations,
                    column: :operation_id, on_delete: :restrict,
                    validate: true
    add_foreign_key :stern_operation_attempts, :stern_operations,
                    column: :operation_id, on_delete: :nullify,
                    validate: true
  end

  def down
    remove_foreign_key :stern_operation_attempts, column: :operation_id
    remove_foreign_key :stern_entry_pairs, column: :operation_id
    remove_foreign_key :stern_entries, column: :entry_pair_id
  end
end
