class CreateCreditTxIdSequence < ActiveRecord::Migration[7.0]
  def up
    execute <<-SQL
      CREATE SEQUENCE IF NOT EXISTS credit_tx_id_seq;
    SQL
  end

  def down
    execute <<-SQL
      DROP SEQUENCE IF EXISTS credit_tx_id_seq;
    SQL
  end
end
