class CreateSternOperationDefs < ActiveRecord::Migration[7.0]
  def change
    create_table :stern_operation_defs do |t|
      t.string :name, null: false, index: true
      t.boolean :active, null: false
      t.boolean :undo_capability, null: false

      t.timestamps
    end
  end
end
