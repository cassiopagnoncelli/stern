class CreateSternOperations < ActiveRecord::Migration[7.0]
  def change
    create_table :stern_operations do |t|
      t.integer :operation_def_id, null: false, index: true
      t.integer :direction, null: false
      t.json :params, null: false, default: '{}'

      t.timestamps
    end
  end
end
