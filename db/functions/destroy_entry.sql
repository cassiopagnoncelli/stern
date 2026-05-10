CREATE OR REPLACE FUNCTION destroy_entry(
  IN in_id BIGINT,
  IN verbose_mode BOOLEAN DEFAULT FALSE
) RETURNS BIGINT AS $$
DECLARE
  entry stern_entries%ROWTYPE;
  nn BOOLEAN;
BEGIN
  IF in_id IS NULL THEN
    RAISE EXCEPTION 'id is undefined';
  END IF;

  SELECT * INTO entry FROM stern_entries WHERE id = in_id LIMIT 1;

  -- Defense-in-depth: serialize cascade recomputation on this
  -- (book_id, gid, currency) tuple against concurrent writers. Taken after the
  -- initial SELECT because we need the row's columns to derive the lock key.
  -- Transaction-scoped; releases at commit/rollback.
  PERFORM pg_advisory_xact_lock(
    hashtextextended(format('stern:%s:%s:%s', entry.book_id, entry.gid, entry.currency), 0)
  );

  SELECT non_negative INTO nn FROM stern_books WHERE id = entry.book_id;
  nn := COALESCE(nn, FALSE);

  IF verbose_mode THEN
    RAISE DEBUG '-- selected row: %', format('%I', entry);
  END IF;

  DELETE FROM stern_entries WHERE id = in_id;

  IF verbose_mode THEN
    RAISE DEBUG '-- updating ending_balance in (book_id=%, gid=%, currency=%) partition after %',
      entry.book_id, entry.gid, entry.currency, entry.timestamp;
  END IF;

  -- This operation is not particularly fast.
  --
  -- Recomputes ending_balance across the entire (book_id, gid, currency)
  -- partition. Strictly speaking only rows at or after entry.timestamp can
  -- change value, but recomputing all is correct and avoids drift from the
  -- post-destroy non_negative check below (see scope rationale there).
  UPDATE stern_entries
  SET ending_balance = mirror.new_ending_balance
  FROM (
    SELECT
      id,
      (SUM(amount) OVER (ORDER BY timestamp)) AS new_ending_balance
    FROM stern_entries
    WHERE book_id = entry.book_id
      AND gid = entry.gid
      AND currency = entry.currency
    ORDER BY timestamp, id
  ) mirror
  WHERE stern_entries.id = mirror.id;

  -- non_negative invariant: post-destroy check.
  -- ----------------------------------------------------------------------
  -- Scope intentionally differs from create_entry's downstream-only
  -- check. Reasoning:
  --   * The UPDATE above recomputes ending_balance for the entire
  --     (book_id, gid, currency) partition (no timestamp filter on the
  --     outer match). Strictly speaking only rows AT or AFTER the
  --     deleted entry's timestamp can change value, but recomputing all
  --     is correct and simpler.
  --   * Mirror that scope here: scan all rows. A `timestamp > entry.timestamp`
  --     filter would also be correct under the current UPDATE, but if
  --     someone later narrows the UPDATE's range without narrowing this
  --     check, the two scopes drift and a pre-existing-but-unrelated
  --     negative could slip through unnoticed. Keeping them both
  --     full-partition makes the contract self-evident.
  IF nn AND EXISTS (
    SELECT 1 FROM stern_entries
    WHERE book_id = entry.book_id
      AND gid = entry.gid
      AND currency = entry.currency
      AND ending_balance < 0
  ) THEN
    RAISE EXCEPTION 'destroy_entry would leave ending_balance negative on non_negative book (book_id=%, gid=%, currency=%)',
      entry.book_id, entry.gid, entry.currency
      USING ERRCODE = '23514', CONSTRAINT = 'stern_books_non_negative';
  END IF;

  RETURN entry.id;
END;
$$ LANGUAGE plpgsql;
