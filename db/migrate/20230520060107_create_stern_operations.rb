class CreateSternOperations < ActiveRecord::Migration[7.0]
  def change
    create_table :stern_operations do |t|
      t.string :name
      t.boolean :active
      t.boolean :undo_capability

      t.timestamps
    end
  end
end
