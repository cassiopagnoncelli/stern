class ReconcileDestroyEntryComment < ActiveRecord::Migration[7.0]
  # Re-executes `destroy_entry.sql` after correcting a stale comment above the
  # cascade UPDATE. The previous comment claimed only rows after entry's
  # timestamp would be updated, but the SQL has no such filter and rewrites the
  # entire (book_id, gid, currency) partition. The replacement comment matches
  # reality and points to the post-destroy non_negative check for the scope
  # rationale. Function body is functionally identical — pure documentation
  # update — but PostgreSQL stores function source verbatim, so the deployed
  # `pg_proc.prosrc` only carries the new commentary after a CREATE OR REPLACE.
  #
  # No data changes; safe to roll forward and back.
  def up
    execute File.read(File.expand_path("../functions/destroy_entry.sql", __dir__))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
