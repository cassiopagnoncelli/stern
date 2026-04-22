class AddCurrencyToSternEntryPairs < ActiveRecord::Migration[7.0]
  def change
    add_column :stern_entry_pairs, :currency, :integer, null: false

    remove_index :stern_entry_pairs, [ :code, :uid ], if_exists: true

    add_index :stern_entry_pairs, [ :code, :currency, :uid ],
              unique: true, if_not_exists: true
  end
end
