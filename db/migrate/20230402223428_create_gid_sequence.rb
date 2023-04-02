class CreateGidSequence < ActiveRecord::Migration[7.0]
  def up
    execute <<-SQL
      CREATE SEQUENCE IF NOT EXISTS gid_seq START 1201;
    SQL
  end

  def down
    execute <<-SQL
      DROP SEQUENCE IF EXISTS gid_seq;
    SQL
  end
end
