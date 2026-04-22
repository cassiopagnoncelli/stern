class AddRetryCountToSternScheduledOperations < ActiveRecord::Migration[7.0]
  def change
    add_column :stern_scheduled_operations, :retry_count, :integer,
               null: false, default: 0
  end
end
