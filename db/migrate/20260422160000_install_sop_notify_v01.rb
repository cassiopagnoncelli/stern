class InstallSopNotifyV01 < ActiveRecord::Migration[7.0]
  def up
    execute File.read(File.expand_path("../functions/sop_notify_v01.sql", __dir__))
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS stern_sop_notify_trigger ON stern_scheduled_operations;
      DROP FUNCTION IF EXISTS stern_sop_notify();
    SQL
  end
end
