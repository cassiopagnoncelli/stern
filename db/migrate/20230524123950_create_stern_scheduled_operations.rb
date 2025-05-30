class CreateSternScheduledOperations < ActiveRecord::Migration[7.0]
  def change
    create_table :stern_scheduled_operations, if_not_exists: true do |t|
      t.timestamps

      t.string :name, null: false, index: true
      t.json :params, null: false, default: {}
      t.datetime :after_time, null: false, index: true
      t.integer :status, null: false, default: 0, index: true
      t.datetime :status_time, null: false
      t.string :error_message
    end
  end
end
