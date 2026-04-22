class AddCurrencyToSternEntries < ActiveRecord::Migration[7.0]
  def change
    add_column :stern_entries, :currency, :integer, null: false

    remove_index :stern_entries, [ :book_id, :gid, :entry_pair_id ], if_exists: true
    remove_index :stern_entries, [ :book_id, :gid, :timestamp ], if_exists: true

    add_index :stern_entries, [ :book_id, :gid, :currency, :entry_pair_id ],
              unique: true, if_not_exists: true,
              name: "index_stern_entries_on_bgce"
    add_index :stern_entries, [ :book_id, :gid, :currency, :timestamp ],
              unique: true, if_not_exists: true,
              name: "index_stern_entries_on_bgct"
  end
end
