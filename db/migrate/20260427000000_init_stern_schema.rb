class InitSternSchema < ActiveRecord::Migration[7.0]
  def up
    create_table :stern_books, if_not_exists: true do |t|
      t.timestamps
      t.string :name, null: false
      t.boolean :non_negative, null: false, default: false
    end
    add_index :stern_books, :name, unique: true

    create_table :stern_entries, if_not_exists: true do |t|
      t.timestamps
      t.integer :book_id, null: false
      t.bigint :gid, null: false
      t.bigint :entry_pair_id, null: false
      t.bigint :amount, null: false
      t.bigint :ending_balance, null: false
      t.datetime :timestamp, null: false
      t.integer :currency, null: false
    end
    add_index :stern_entries, [ :book_id, :gid, :currency, :entry_pair_id ],
              unique: true, name: "index_stern_entries_on_bgce"
    add_index :stern_entries, [ :book_id, :gid, :currency, :timestamp ],
              unique: true, name: "index_stern_entries_on_bgct"

    create_table :stern_entry_pairs, if_not_exists: true do |t|
      t.timestamps
      t.integer :code, null: false
      t.bigint :uid, null: false
      t.bigint :amount, null: false
      t.datetime :timestamp, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.bigint :operation_id, null: false
      t.integer :currency, null: false
    end
    add_index :stern_entry_pairs, [ :code, :currency, :uid ]
    add_index :stern_entry_pairs, :operation_id

    create_table :stern_operations, if_not_exists: true do |t|
      t.timestamps
      t.string :name, null: false
      t.json :params, null: false, default: "{}"
      t.string :idem_key, null: true, limit: 24
    end
    add_index :stern_operations, :name
    add_index :stern_operations, :idem_key, unique: true,
                                             where: "idem_key IS NOT NULL"

    create_table :stern_operation_attempts, if_not_exists: true do |t|
      t.timestamps
      t.string :name, null: false
      t.json :params, null: false, default: "{}"
      t.string :idem_key, null: true, limit: 24
      t.bigint :operation_id, null: true
      t.integer :status, null: false, default: 0
      t.string :error_class, null: true
      t.text :error_message, null: true
      t.text :error_backtrace, null: true
      t.datetime :attempted_at, null: false
    end
    add_index :stern_operation_attempts, :name
    add_index :stern_operation_attempts, :idem_key
    add_index :stern_operation_attempts, :operation_id
    add_index :stern_operation_attempts, :status
    add_index :stern_operation_attempts, :attempted_at

    create_table :stern_scheduled_operations, if_not_exists: true do |t|
      t.timestamps
      t.string :name, null: false
      t.json :params, null: false, default: {}
      t.datetime :after_time, null: false
      t.integer :status, null: false, default: 0
      t.datetime :status_time, null: false
      t.string :error_message
      t.integer :retry_count, null: false, default: 0
    end
    add_index :stern_scheduled_operations, :name
    add_index :stern_scheduled_operations, :after_time
    add_index :stern_scheduled_operations, :status

    # Record graph (Entry -> EntryPair -> Operation, OperationAttempt -> Operation)
    # is enforced at the DB layer so direct SQL writes and partial cleanup paths
    # cannot leave orphans. on_delete semantics:
    #   - entries -> entry_pairs:           :restrict (Entry rows are append-only;
    #                                       Repair.clear deletes Entry first)
    #   - entry_pairs -> operations:        :restrict (same Repair.clear ordering)
    #   - operation_attempts -> operations: :nullify  (attempts can pre-exist their
    #                                       op; Operation rows can be cleared
    #                                       without losing the post-mortem record)
    add_foreign_key :stern_entries, :stern_entry_pairs,
                    column: :entry_pair_id, on_delete: :restrict,
                    validate: true
    add_foreign_key :stern_entry_pairs, :stern_operations,
                    column: :operation_id, on_delete: :restrict,
                    validate: true
    add_foreign_key :stern_operation_attempts, :stern_operations,
                    column: :operation_id, on_delete: :nullify,
                    validate: true

    execute File.read(File.expand_path("../functions/stern_advisory_lock_key.sql", __dir__))
    execute File.read(File.expand_path("../functions/create_entry.sql", __dir__))
    execute File.read(File.expand_path("../functions/destroy_entry.sql", __dir__))
    execute File.read(File.expand_path("../functions/sop_notify.sql", __dir__))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
