class CreateSternOperations < ActiveRecord::Migration[7.0]
  def change
    create_table :stern_operations, if_not_exists: true do |t|
      t.timestamps

      t.string :name, null: false
      t.json :params, null: false, default: "{}"
      t.string :idem_key, null: true, limit: 24
    end

    add_index :stern_operations, :name
    add_index :stern_operations, :idem_key, unique: true, where: "idem_key IS NOT NULL"
  end
end
