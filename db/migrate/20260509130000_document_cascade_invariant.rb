class DocumentCascadeInvariant < ActiveRecord::Migration[7.0]
  # Re-executes `create_entry.sql` and `destroy_entry.sql` after their
  # non_negative invariant checks were annotated with explanatory comments.
  # Function bodies are functionally identical to the prior version — pure
  # documentation update — but PostgreSQL stores function source verbatim,
  # so the deployed `pg_proc.prosrc` only carries the new commentary after a
  # CREATE OR REPLACE. Running this migration brings existing installs in
  # line with the source so `\sf create_entry` in psql shows the same body
  # a developer reads in db/functions/.
  #
  # No data changes; safe to roll forward and back.
  def up
    execute File.read(File.expand_path("../functions/create_entry.sql", __dir__))
    execute File.read(File.expand_path("../functions/destroy_entry.sql", __dir__))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
