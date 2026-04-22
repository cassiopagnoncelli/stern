CREATE OR REPLACE FUNCTION destroy_entry(
  IN in_id BIGINT,
  IN verbose_mode BOOLEAN DEFAULT FALSE
) RETURNS BIGINT AS $$
DECLARE
  entry stern_entries%ROWTYPE;
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

  RAISE NOTICE 'Selected row: %', format('%I', entry);

  DELETE FROM stern_entries WHERE id = in_id;

  IF verbose_mode THEN
    RAISE DEBUG '-- updating ending_balance in (book_id=%, gid=%, currency=%) partition after %',
      entry.book_id, entry.gid, entry.currency, entry.timestamp;
  END IF;

  -- This operation is not particularly fast.
  --
  -- Only timestamps after entry should be updated (stern_entries.timestamp > entry.timestamp).
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

  RETURN entry.id;
END;
$$ LANGUAGE plpgsql;
