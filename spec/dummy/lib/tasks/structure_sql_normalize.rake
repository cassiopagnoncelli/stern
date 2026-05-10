# frozen_string_literal: true

# Normalize pg_dump output so the committed structure.sql is portable across
# PG versions and dump environments:
#   * Strip the `Dumped from database version ...` / `Dumped by pg_dump version ...`
#     header comments — they encode the local PG build (e.g. "17.9 (Postgres.app)"
#     vs "16.13 (Debian)") and would flap the drift guard between dev and CI.
#   * Strip `SET transaction_timeout = 0;`, a PG 17+ default that PG 14/15/16
#     reject as "unrecognized configuration parameter" on schema:load.
Rake::Task["db:schema:dump"].enhance do
  structure_path = Rails.root.join("db/structure.sql")
  if File.exist?(structure_path)
    original = File.read(structure_path)
    cleaned = original
      .gsub(/^-- Dumped (?:from database|by pg_dump) version .*\n/, "")
      .gsub(/^SET transaction_timeout = 0;\n/, "")
    File.write(structure_path, cleaned) if cleaned != original
  end
end
