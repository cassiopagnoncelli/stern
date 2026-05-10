# frozen_string_literal: true

# pg_dump emits PG-version-specific `SET` statements at the top of structure.sql.
# When the dump is generated on PG 17+ but loaded on PG 14/15/16 (e.g. CI matrix),
# those settings fail with "unrecognized configuration parameter". Strip the ones
# that are post-PG-16 additions and would be no-ops at their default values anyway.
Rake::Task["db:schema:dump"].enhance do
  structure_path = Rails.root.join("db/structure.sql")
  if File.exist?(structure_path)
    original = File.read(structure_path)
    cleaned = original.gsub(/^SET transaction_timeout = 0;\n/, "")
    File.write(structure_path, cleaned) if cleaned != original
  end
end
