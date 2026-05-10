class GateDestroyEntryNotice < ActiveRecord::Migration[7.0]
  # Re-executes `destroy_entry.sql` after gating the previously-unconditional
  # `RAISE NOTICE 'Selected row: ...'` behind `verbose_mode` (now a
  # `RAISE DEBUG`, matching surrounding style). Without this re-execution the
  # deployed `pg_proc.prosrc` would still emit one NOTICE per destroy and
  # flood production logs.
  #
  # No data changes; safe to roll forward and back.
  def up
    execute File.read(File.expand_path("../functions/destroy_entry.sql", __dir__))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
