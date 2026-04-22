# frozen_string_literal: true

# Normalizes `structure.sql` dumps produced by pg_dump 18+ so the committed
# file stays stable across runs and CI's drift guard can catch actual schema
# changes instead of session-token noise.
#
# pg_dump (≥ 18, also Postgres.app 17.x) emits `\restrict <random-token>` and
# `\unrestrict <random-token>` psql directives that sandbox the dump replay.
# The token is generated fresh per invocation, so the file differs on every
# regen. This patch strips those directives after the dump, leaving the
# schema-bearing content intact.
module Stern
  module StructureSqlNormalize
    def structure_dump(filename, extra_flags)
      super
      return unless File.exist?(filename)

      content = File.read(filename)
      cleaned = content.gsub(/^\\(?:un)?restrict \S+\n/, "")
      File.write(filename, cleaned) if cleaned != content
    end
  end
end

ActiveSupport.on_load(:active_record) do
  ActiveRecord::Tasks::PostgreSQLDatabaseTasks.prepend(Stern::StructureSqlNormalize)
end
