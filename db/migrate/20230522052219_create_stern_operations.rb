class CreateSternOperations < ActiveRecord::Migration[7.0]
  def change
    create_table :stern_operations, if_not_exists: true do |t|
      t.timestamps

      t.string :name, null: false, index: true
      t.integer :direction, null: false
      t.json :params, null: false, default: "{}"
    end
  end
end
