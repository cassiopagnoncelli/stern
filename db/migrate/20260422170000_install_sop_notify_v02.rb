class InstallSopNotifyV02 < ActiveRecord::Migration[7.0]
  def up
    execute File.read(File.expand_path("../functions/sop_notify_v02.sql", __dir__))
  end

  def down
    execute File.read(File.expand_path("../functions/sop_notify_v01.sql", __dir__))
  end
end
