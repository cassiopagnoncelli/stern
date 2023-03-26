class CreateSternEntries < ActiveRecord::Migration[7.0]
  def change
    create_table :stern_entries do |t|
      t.integer :book_id, null: false
      t.integer :gid, null: false
      t.bigint :tx_id, null: false
      t.bigint :amount, null: false
      t.bigint :ending_balance, null: false
      t.datetime :timestamp, null: false

      t.timestamps
    end
    add_index :stern_entries, [:book_id, :gid, :tx_id], unique: true
    add_index :stern_entries, [:book_id, :gid, :timestamp], unique: true
  end
end
