class CreateSternEntryPairs < ActiveRecord::Migration[7.0]
  def change
    create_table :stern_entry_pairs, if_not_exists: true do |t|
      t.timestamps

      t.integer :code, null: false
      t.bigint :uid, null: false
      t.bigint :amount, null: false
      t.datetime :timestamp, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.bigint :credit_entry_pair_id
      t.bigint :operation_id, null: false, index: true
    end
    add_index :stern_entry_pairs, [:code, :uid], unique: true, if_not_exists: true
  end
end
