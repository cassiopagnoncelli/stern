class CreateEntryFunction < ActiveRecord::Migration[7.0]
  def up
    execute File.read(File.expand_path("../functions/create_entry_v01.sql", __dir__))
  end

  def down
    execute "DROP FUNCTION IF EXISTS create_entry"
  end
end
