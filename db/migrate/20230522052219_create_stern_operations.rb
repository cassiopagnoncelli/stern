class CreateSternOperations < ActiveRecord::Migration[7.0]
  def change
    create_table :stern_operations do |t|
      t.string :name, null: false
      t.integer :direction, null: false
      t.json :params, null: false, default: '{}'

      t.timestamps
    end
  end
end
