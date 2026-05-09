class AddSternOperationAttempts < ActiveRecord::Migration[7.0]
  def up
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
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
