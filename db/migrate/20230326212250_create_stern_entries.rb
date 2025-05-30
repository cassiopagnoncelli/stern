class CreateSternEntries < ActiveRecord::Migration[7.0]
  def change
    create_table :stern_entries, if_not_exists: true do |t|
      t.integer :book_id, null: false
      t.integer :gid, null: false
      t.bigint :entry_pair_id, null: false
      t.bigint :amount, null: false
      t.bigint :ending_balance, null: false
      t.datetime :timestamp, null: false

      t.timestamps
    end
    add_index :stern_entries, [:book_id, :gid, :entry_pair_id], unique: true, if_not_exists: true
    add_index :stern_entries, [:book_id, :gid, :timestamp], unique: true, if_not_exists: true
  end
end
