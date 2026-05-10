-- Single source of truth for the per-tuple advisory lock key.
--
-- Every writer that touches a `(book_id, gid, currency)` partition must take
-- the same Postgres advisory lock so cascade computations serialize cleanly.
-- Three layers do this — `Stern::ApplicationRecord.advisory_lock` (used by
-- `BaseOperation#acquire_advisory_locks` and `Stern::Repair`), `create_entry`
-- v03, and `destroy_entry` v03 — and historically each layer hand-rolled the
-- same `hashtextextended(format('stern:%s:%s:%s', ...), 0)` expression.
-- Any divergence (a renamed prefix, a reordered tuple) silently disables the
-- serialization on whichever site forgot to update.
--
-- Routing every caller through this function collapses those four copies into
-- one definition: a change here is the only way to change the key, and all
-- sites pick it up. `spec/services/stern/advisory_lock_key_spec.rb` pins the
-- hash for a known input so silent formula edits fail loudly.
--
-- Marked IMMUTABLE + PARALLEL SAFE: the output depends only on the inputs,
-- with no side effects, so the planner is free to fold and parallelize calls.
CREATE OR REPLACE FUNCTION stern_advisory_lock_key(
  IN in_book_id INTEGER,
  IN in_gid BIGINT,
  IN in_currency INTEGER
)
RETURNS BIGINT
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT hashtextextended(
    format('stern:%s:%s:%s', in_book_id, in_gid, in_currency),
    0
  );
$$;
