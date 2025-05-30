class CreateCreditEntryPairIdSequence < ActiveRecord::Migration[7.0]
  def up
    execute <<-SQL
      CREATE SEQUENCE IF NOT EXISTS credit_entry_pair_id_seq;
    SQL
  end

  def down
    execute <<-SQL
      DROP SEQUENCE IF EXISTS credit_entry_pair_id_seq;
    SQL
  end
end
