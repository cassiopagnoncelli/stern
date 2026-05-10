class CentralizeAdvisoryLockKey < ActiveRecord::Migration[7.0]
  # Installs the `stern_advisory_lock_key` SQL function — the single
  # definition of the per-tuple advisory lock key — and re-executes
  # `create_entry.sql` and `destroy_entry.sql` so their bodies route through
  # it instead of hand-rolling the same `hashtextextended(format(...), 0)`
  # expression. The Ruby side (`ApplicationRecord.advisory_lock`) and the
  # `repair_concurrency_spec` lock-key fragment now also delegate to the
  # function, collapsing four hand-rolled copies of the formula into one.
  #
  # The function body is identical to the inline expression every site
  # previously used, so the bigint key for any `(book_id, gid, currency)`
  # tuple is unchanged — in-flight locks taken before the migration land
  # remain compatible with locks taken after.
  #
  # No data changes; safe to roll forward.
  def up
    execute File.read(File.expand_path("../functions/stern_advisory_lock_key.sql", __dir__))
    execute File.read(File.expand_path("../functions/create_entry.sql", __dir__))
    execute File.read(File.expand_path("../functions/destroy_entry.sql", __dir__))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
