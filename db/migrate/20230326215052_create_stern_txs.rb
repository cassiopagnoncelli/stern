class CreateSternTxs < ActiveRecord::Migration[7.0]
  def change
    create_table :stern_txs, if_not_exists: true do |t|
      t.integer :code, null: false
      t.bigint :uid, null: false
      t.bigint :amount, null: false
      t.datetime :timestamp, null: false
      t.bigint :credit_tx_id

      t.timestamps
    end
    add_index :stern_txs, [:code, :uid], unique: true, if_not_exists: true
  end
end
