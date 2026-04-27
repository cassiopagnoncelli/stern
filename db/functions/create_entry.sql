CREATE OR REPLACE FUNCTION create_entry(
  IN in_book_id INTEGER,
  IN in_gid BIGINT,
  IN in_entry_pair_id BIGINT,
  IN in_amount BIGINT,
  IN in_currency INTEGER,
  IN in_timestamp_utc TIMESTAMP(6) DEFAULT NULL,
  IN verbose_mode BOOLEAN DEFAULT FALSE
)
RETURNS stern_entries AS $$
DECLARE
  entry stern_entries;
  ts TIMESTAMP(6) WITHOUT TIME ZONE;
  cascade BOOLEAN;
  nn BOOLEAN;
BEGIN
  IF in_book_id IS NULL OR in_gid IS NULL OR in_entry_pair_id IS NULL
      OR in_amount IS NULL OR in_amount = 0 OR in_currency IS NULL THEN
    RAISE EXCEPTION 'book_id, gid, entry_pair_id, currency should be defined, amount should be non-zero integer';
  END IF;

  -- Defense-in-depth: serialize cascade computation on this (book_id, gid, currency)
  -- tuple against any other concurrent writer, even if the caller bypassed the
  -- operation-level advisory lock in BaseOperation#call. Transaction-scoped;
  -- releases at commit/rollback. Same hash shape as BaseOperation#acquire_advisory_locks
  -- so the two layers grab the same lock and are reentrant.
  PERFORM pg_advisory_xact_lock(
    hashtextextended(format('stern:%s:%s:%s', in_book_id, in_gid, in_currency), 0)
  );

  -- Chart-level non_negative flag: if set, reject any write that leaves
  -- ending_balance < 0 on this book, either on the inserted row or on any row
  -- downstream of a past-timestamp cascade.
  SELECT non_negative INTO nn FROM stern_books WHERE id = in_book_id;
  nn := COALESCE(nn, FALSE);

  ts := CAST(timezone('UTC', clock_timestamp()) AS TIMESTAMP(6) WITHOUT TIME ZONE);

  IF in_timestamp_utc IS NOT NULL AND in_timestamp_utc > ts THEN
    RAISE EXCEPTION 'timestamp %s cannot be in the future', in_timestamp_utc;
  END IF;

  entry.book_id := in_book_id;
  entry.gid := in_gid;
  entry.entry_pair_id := in_entry_pair_id;
  entry.amount := in_amount;
  entry.currency := in_currency;
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
    entry.timestamp := in_timestamp_utc::timestamp WITH TIME ZONE AT TIME ZONE 'UTC';
    IF verbose_mode THEN
      RAISE DEBUG '-- entry.timestamp = %', entry.timestamp;
    END IF;
  END IF;

  entry.ending_balance := COALESCE((
    SELECT COALESCE(stern_entries.ending_balance, 0)
    FROM stern_entries
    WHERE book_id = entry.book_id
      AND gid = entry.gid
      AND currency = entry.currency
      AND timestamp < entry.timestamp
    ORDER BY timestamp DESC, id DESC
    LIMIT 1
  ), 0) + entry.amount;

  IF verbose_mode THEN
    RAISE DEBUG '-- last ending_balance is %', (
      SELECT timestamp
      FROM stern_entries
      WHERE book_id = entry.book_id
        AND gid = entry.gid
        AND currency = entry.currency
        AND timestamp < entry.timestamp
      ORDER BY timestamp DESC, id DESC
      LIMIT 1
    );
    RAISE DEBUG '-- ending_balance for the new record is %', entry.ending_balance;
  END IF;

  IF nn AND entry.ending_balance < 0 THEN
    RAISE EXCEPTION 'balance would go negative on non_negative book (book_id=%, gid=%, currency=%, computed=%)',
      in_book_id, in_gid, in_currency, entry.ending_balance
      USING ERRCODE = '23514', CONSTRAINT = 'stern_books_non_negative';
  END IF;

  INSERT INTO stern_entries (
    book_id,
    gid,
    entry_pair_id,
    amount,
    currency,
    ending_balance,
    timestamp,
    created_at,
    updated_at
  ) VALUES (
    entry.book_id,
    entry.gid,
    entry.entry_pair_id,
    entry.amount,
    entry.currency,
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
      RAISE DEBUG '-- (book_id, gid, currency) has % records, % records will be updated', (
        SELECT COUNT(*) FROM (
          SELECT
            id,
            (SUM(amount) OVER (ORDER BY timestamp)) AS new_ending_balance
          FROM stern_entries
          WHERE book_id = entry.book_id
            AND gid = entry.gid
            AND currency = entry.currency
          ORDER BY timestamp, id
        ) x
      ), (
        SELECT COUNT(*)
        FROM stern_entries
        WHERE book_id = entry.book_id
          AND gid = entry.gid
          AND currency = entry.currency
          AND timestamp > entry.timestamp
      );
    END IF;

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
    WHERE stern_entries.id = mirror.id AND stern_entries.timestamp > entry.timestamp;

    IF nn AND EXISTS (
      SELECT 1 FROM stern_entries
      WHERE book_id = entry.book_id
        AND gid = entry.gid
        AND currency = entry.currency
        AND timestamp > entry.timestamp
        AND ending_balance < 0
    ) THEN
      RAISE EXCEPTION 'past-timestamp insert would leave subsequent ending_balance negative on non_negative book (book_id=%, gid=%, currency=%)',
        entry.book_id, entry.gid, entry.currency
        USING ERRCODE = '23514', CONSTRAINT = 'stern_books_non_negative';
    END IF;
  END IF;

  RETURN entry;
END;
$$ LANGUAGE plpgsql;
