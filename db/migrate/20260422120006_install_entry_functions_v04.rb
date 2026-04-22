class InstallEntryFunctionsV04 < ActiveRecord::Migration[7.0]
  def up
    execute File.read(File.expand_path("../functions/create_entry_v04.sql", __dir__))
    execute File.read(File.expand_path("../functions/destroy_entry_v04.sql", __dir__))
  end

  def down
    execute File.read(File.expand_path("../functions/create_entry_v03.sql", __dir__))
    execute File.read(File.expand_path("../functions/destroy_entry_v03.sql", __dir__))
  end
end
