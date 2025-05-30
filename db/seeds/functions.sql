-- SET client_min_messages = 'WARNING';
-- RESET client_min_messages;

--
-- db/migrate/20230326215510_create_credit_entry_pair_id_sequence.rb
--
CREATE SEQUENCE IF NOT EXISTS credit_entry_pair_id_seq;

--
-- db/migrate/20230402223428_create_gid_sequence.rb
--
CREATE SEQUENCE IF NOT EXISTS gid_seq START 1201;

--
-- db/migrate/20230407233646_create_entry_function.rb
--
CREATE OR REPLACE FUNCTION create_entry(
  IN in_book_id INTEGER,
  IN in_gid INTEGER,
  IN in_entry_pair_id BIGINT,
  IN in_amount BIGINT,
  IN in_timestamp_utc TIMESTAMP(6) DEFAULT NULL,
  IN verbose_mode BOOLEAN DEFAULT FALSE
)
RETURNS stern_entries AS $$
DECLARE
  entry stern_entries;
  ts TIMESTAMP(6) WITHOUT TIME ZONE;
  cascade BOOLEAN;
BEGIN
  IF in_book_id IS NULL OR in_gid IS NULL OR in_entry_pair_id IS NULL OR in_amount IS NULL OR in_amount = 0 THEN
    RAISE EXCEPTION 'book_id, gid, entry_pair_id should be defined, amount should be non-zero integer';
  END IF;

  ts := CAST(timezone('UTC', clock_timestamp()) AS TIMESTAMP(6) WITHOUT TIME ZONE);

  IF in_timestamp_utc IS NOT NULL AND in_timestamp_utc > ts THEN
    RAISE EXCEPTION 'timestamp %s cannot be in the future', in_timestamp_utc;
  END IF;

  entry.book_id := in_book_id;
  entry.gid := in_gid;
  entry.entry_pair_id := in_entry_pair_id;
  entry.amount := in_amount;
  entry.created_at := ts;
  entry.updated_at := ts;

  IF in_timestamp_utc IS NULL THEN
    cascade := FALSE;
    entry.timestamp := ts;
    IF verbose_mode THEN
      RAISE DEBUG '-- entry.timestamp is null and was set to be %', entry.timestamp;
    END IF;
  ELSE
    cascade := TRUE;
    entry.timestamp := in_timestamp_utc::timestamp WITH TIME ZONE AT TIME ZONE 'UTC'; -- CAST(timezone('UTC', in_timestamp_utc) AS TIMESTAMP(6) WITHOUT TIME ZONE);
    IF verbose_mode THEN
      RAISE DEBUG '-- entry.timestamp = %', entry.timestamp;
    END IF;
  END IF;

  entry.ending_balance := COALESCE((
    SELECT COALESCE(stern_entries.ending_balance, 0)
    FROM stern_entries
    WHERE book_id = entry.book_id
      AND gid = entry.gid
      AND timestamp < entry.timestamp
    ORDER BY timestamp DESC, id DESC
    LIMIT 1
  ), 0) + entry.amount;

  IF verbose_mode THEN
    RAISE DEBUG '-- last ending_balance is %', (
      SELECT timestamp
      FROM stern_entries
      WHERE timestamp < entry.timestamp
      ORDER BY timestamp DESC, id DESC
      LIMIT 1
    );
    RAISE DEBUG '-- ending_balance for the new record is %', entry.ending_balance;
  END IF;

  INSERT INTO stern_entries (
    book_id,
    gid,
    entry_pair_id,
    amount,
    ending_balance,
    timestamp,
    created_at,
    updated_at
  ) VALUES (
    entry.book_id,
    entry.gid,
    entry.entry_pair_id,
    entry.amount,
    entry.ending_balance,
    entry.timestamp,
    entry.created_at,
    entry.updated_at
  )
  RETURNING * INTO entry;

  IF verbose_mode THEN
    RAISE DEBUG '-- row is now recorded';
  END IF;

  IF cascade THEN
    IF verbose_mode THEN
      RAISE DEBUG '-- with timestamp, ending_balance will be cascaded for the next records';
      RAISE DEBUG '-- (book_id, gid) has % records, % records will be updated', (
        SELECT COUNT(*) FROM (
          SELECT
            id,
            (SUM(amount) OVER (ORDER BY timestamp)) AS new_ending_balance
          FROM stern_entries
          WHERE book_id = entry.book_id AND gid = entry.gid
          ORDER BY timestamp, id
        ) x
      ), (
        SELECT COUNT(*)
        FROM stern_entries
        WHERE book_id = entry.book_id AND gid = entry.gid AND timestamp > entry.timestamp
      );
    END IF;

    UPDATE stern_entries
    SET ending_balance = mirror.new_ending_balance
    FROM (
      SELECT
        id,
        (SUM(amount) OVER (ORDER BY timestamp)) AS new_ending_balance
      FROM stern_entries
      WHERE book_id = entry.book_id AND gid = entry.gid
      ORDER BY timestamp, id
    ) mirror
    WHERE stern_entries.id = mirror.id AND stern_entries.timestamp > entry.timestamp;
  END IF;

  RETURN entry;
END;
$$ LANGUAGE plpgsql;

--
-- db/migrate/20230408022903_destroy_entry_function.rb
--
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

  RAISE NOTICE 'Selected row: %', format('%I', entry);

  DELETE FROM stern_entries WHERE id = in_id;

  IF verbose_mode THEN
    RAISE DEBUG '-- updating ending_balance in (book_id=%, gid=%) pair after %',
      entry.book_id, entry.gid, entry.timestamp;
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
    WHERE book_id = entry.book_id AND gid = entry.gid
    ORDER BY timestamp, id
  ) mirror
  WHERE stern_entries.id = mirror.id;

  RETURN entry.id;
END;
$$ LANGUAGE plpgsql;

--
--
--
