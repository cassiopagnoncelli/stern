class InitSternSchema < ActiveRecord::Migration[7.0]
  def up
    execute "CREATE SEQUENCE IF NOT EXISTS gid_seq START 1201;"

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
    add_index :stern_entry_pairs, [ :code, :currency, :uid ], unique: true
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

    execute File.read(File.expand_path("../functions/create_entry.sql", __dir__))
    execute File.read(File.expand_path("../functions/destroy_entry.sql", __dir__))
    execute File.read(File.expand_path("../functions/sop_notify.sql", __dir__))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
