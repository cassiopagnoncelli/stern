class CreateSternScheduledOperations < ActiveRecord::Migration[7.0]
  def change
    create_table :stern_scheduled_operations do |t|
      t.integer :operation_def_id, null: false
      t.json :params, null: false, default: {}
      t.datetime :after_time, null: false
      t.integer :status, null: false, default: 0
      t.datetime :status_time, null: false
      t.string :error_message

      t.timestamps
    end
    add_index :stern_scheduled_operations, :operation_def_id
    add_index :stern_scheduled_operations, :after_time
    add_index :stern_scheduled_operations, :status
  end
end
