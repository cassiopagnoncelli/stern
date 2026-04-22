class CreateEntryFunctionV02 < ActiveRecord::Migration[7.0]
  def up
    execute "DROP FUNCTION IF EXISTS create_entry(INTEGER, BIGINT, BIGINT, BIGINT, TIMESTAMP, BOOLEAN)"
    execute File.read(File.expand_path("../functions/create_entry_v02.sql", __dir__))
  end

  def down
    execute "DROP FUNCTION IF EXISTS create_entry(INTEGER, BIGINT, BIGINT, BIGINT, INTEGER, TIMESTAMP, BOOLEAN)"
    execute File.read(File.expand_path("../functions/create_entry_v01.sql", __dir__))
  end
end
