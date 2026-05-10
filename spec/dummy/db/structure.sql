
-- Dumped from database version 17.9 (Postgres.app)
-- Dumped by pg_dump version 17.9 (Postgres.app)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: stern_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stern_entries (
    id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    book_id integer NOT NULL,
    gid bigint NOT NULL,
    entry_pair_id bigint NOT NULL,
    amount bigint NOT NULL,
    ending_balance bigint NOT NULL,
    "timestamp" timestamp(6) without time zone NOT NULL,
    currency integer NOT NULL
);


--
-- Name: create_entry(integer, bigint, bigint, bigint, integer, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_entry(in_book_id integer, in_gid bigint, in_entry_pair_id bigint, in_amount bigint, in_currency integer, in_timestamp_utc timestamp without time zone DEFAULT NULL::timestamp without time zone, verbose_mode boolean DEFAULT false) RETURNS public.stern_entries
    LANGUAGE plpgsql
    AS $$
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
  -- releases at commit/rollback. Routes through `stern_advisory_lock_key` —
  -- the single definition shared with `BaseOperation#acquire_advisory_locks`,
  -- `destroy_entry`, and `Stern::Repair` — so all layers grab the same lock
  -- and are reentrant.
  PERFORM pg_advisory_xact_lock(
    stern_advisory_lock_key(in_book_id, in_gid, in_currency)
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

  -- non_negative invariant: pre-insert check.
  -- ----------------------------------------------------------------------
  -- This guards the inserted row only. Every prior row in the partition
  -- was already valid before this call, and a non-cascade insert appends
  -- at the tail (clock-now timestamp) so it can't affect their values —
  -- only the new row's ending_balance is at risk. The cascade branch
  -- below adds a SECOND, separate check covering downstream rows; the
  -- two checks have different scopes by design and must NOT be merged
  -- (a non-cascade insert has no downstream to scan, and a cascade
  -- insert has already passed this same row-level check by the time it
  -- arrives at the downstream check).
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

    -- non_negative invariant: post-cascade check.
    -- --------------------------------------------------------------------
    -- The inserted row itself was already validated by the pre-insert
    -- check above (its ending_balance was computed from prior partial
    -- sum + amount before the INSERT). What's new on the cascade leg
    -- is that the UPDATE above rewrote ending_balance on EVERY row at
    -- a later timestamp, folding in `entry.amount` — any of those rows
    -- could now be negative even though they were valid before this
    -- past-timestamp insert. Scan downstream-only: rows upstream of
    -- entry.timestamp weren't touched by the UPDATE and don't need
    -- re-checking. Do NOT consolidate this with the pre-insert check
    -- (different scope: that one is one row, this one is N rows) and
    -- do NOT widen to all rows (the UPDATE's WHERE explicitly excludes
    -- upstream — the two scopes must stay aligned).
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
$$;


--
-- Name: destroy_entry(bigint, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.destroy_entry(in_id bigint, verbose_mode boolean DEFAULT false) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
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
  -- Transaction-scoped; releases at commit/rollback. Routes through
  -- `stern_advisory_lock_key` so this lock collides with the one taken by
  -- `BaseOperation#acquire_advisory_locks`, `create_entry`, and `Stern::Repair`.
  PERFORM pg_advisory_xact_lock(
    stern_advisory_lock_key(entry.book_id, entry.gid, entry.currency)
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
$$;


--
-- Name: stern_advisory_lock_key(integer, bigint, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.stern_advisory_lock_key(in_book_id integer, in_gid bigint, in_currency integer) RETURNS bigint
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$
  SELECT hashtextextended(
    format('stern:%s:%s:%s', in_book_id, in_gid, in_currency),
    0
  );
$$;


--
-- Name: stern_sop_notify(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.stern_sop_notify() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.status = 0 AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status) THEN
    PERFORM pg_notify('stern_scheduled_operations_pending', NEW.id::text);
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: stern_books; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stern_books (
    id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    name character varying NOT NULL,
    non_negative boolean DEFAULT false NOT NULL
);


--
-- Name: stern_books_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.stern_books_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: stern_books_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.stern_books_id_seq OWNED BY public.stern_books.id;


--
-- Name: stern_entries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.stern_entries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: stern_entries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.stern_entries_id_seq OWNED BY public.stern_entries.id;


--
-- Name: stern_entry_pairs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stern_entry_pairs (
    id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    code integer NOT NULL,
    uid bigint NOT NULL,
    amount bigint NOT NULL,
    "timestamp" timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    operation_id bigint NOT NULL,
    currency integer NOT NULL
);


--
-- Name: stern_entry_pairs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.stern_entry_pairs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: stern_entry_pairs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.stern_entry_pairs_id_seq OWNED BY public.stern_entry_pairs.id;


--
-- Name: stern_operation_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stern_operation_attempts (
    id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    name character varying NOT NULL,
    params json DEFAULT '"{}"'::json NOT NULL,
    idem_key character varying(24),
    operation_id bigint,
    status integer DEFAULT 0 NOT NULL,
    error_class character varying,
    error_message text,
    error_backtrace text,
    attempted_at timestamp(6) without time zone NOT NULL
);


--
-- Name: stern_operation_attempts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.stern_operation_attempts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: stern_operation_attempts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.stern_operation_attempts_id_seq OWNED BY public.stern_operation_attempts.id;


--
-- Name: stern_operations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stern_operations (
    id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    name character varying NOT NULL,
    params json DEFAULT '"{}"'::json NOT NULL,
    idem_key character varying(24)
);


--
-- Name: stern_operations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.stern_operations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: stern_operations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.stern_operations_id_seq OWNED BY public.stern_operations.id;


--
-- Name: stern_scheduled_operations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stern_scheduled_operations (
    id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    name character varying NOT NULL,
    params json DEFAULT '{}'::json NOT NULL,
    after_time timestamp(6) without time zone NOT NULL,
    status integer DEFAULT 0 NOT NULL,
    status_time timestamp(6) without time zone NOT NULL,
    error_message character varying,
    retry_count integer DEFAULT 0 NOT NULL
);


--
-- Name: stern_scheduled_operations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.stern_scheduled_operations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: stern_scheduled_operations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.stern_scheduled_operations_id_seq OWNED BY public.stern_scheduled_operations.id;


--
-- Name: stern_books id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stern_books ALTER COLUMN id SET DEFAULT nextval('public.stern_books_id_seq'::regclass);


--
-- Name: stern_entries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stern_entries ALTER COLUMN id SET DEFAULT nextval('public.stern_entries_id_seq'::regclass);


--
-- Name: stern_entry_pairs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stern_entry_pairs ALTER COLUMN id SET DEFAULT nextval('public.stern_entry_pairs_id_seq'::regclass);


--
-- Name: stern_operation_attempts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stern_operation_attempts ALTER COLUMN id SET DEFAULT nextval('public.stern_operation_attempts_id_seq'::regclass);


--
-- Name: stern_operations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stern_operations ALTER COLUMN id SET DEFAULT nextval('public.stern_operations_id_seq'::regclass);


--
-- Name: stern_scheduled_operations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stern_scheduled_operations ALTER COLUMN id SET DEFAULT nextval('public.stern_scheduled_operations_id_seq'::regclass);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: stern_books stern_books_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stern_books
    ADD CONSTRAINT stern_books_pkey PRIMARY KEY (id);


--
-- Name: stern_entries stern_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stern_entries
    ADD CONSTRAINT stern_entries_pkey PRIMARY KEY (id);


--
-- Name: stern_entry_pairs stern_entry_pairs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stern_entry_pairs
    ADD CONSTRAINT stern_entry_pairs_pkey PRIMARY KEY (id);


--
-- Name: stern_operation_attempts stern_operation_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stern_operation_attempts
    ADD CONSTRAINT stern_operation_attempts_pkey PRIMARY KEY (id);


--
-- Name: stern_operations stern_operations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stern_operations
    ADD CONSTRAINT stern_operations_pkey PRIMARY KEY (id);


--
-- Name: stern_scheduled_operations stern_scheduled_operations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stern_scheduled_operations
    ADD CONSTRAINT stern_scheduled_operations_pkey PRIMARY KEY (id);


--
-- Name: index_stern_books_on_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_stern_books_on_name ON public.stern_books USING btree (name);


--
-- Name: index_stern_entries_on_bgce; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_stern_entries_on_bgce ON public.stern_entries USING btree (book_id, gid, currency, entry_pair_id);


--
-- Name: index_stern_entries_on_bgct; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_stern_entries_on_bgct ON public.stern_entries USING btree (book_id, gid, currency, "timestamp");


--
-- Name: index_stern_entry_pairs_on_code_and_currency_and_uid; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stern_entry_pairs_on_code_and_currency_and_uid ON public.stern_entry_pairs USING btree (code, currency, uid);


--
-- Name: index_stern_entry_pairs_on_operation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stern_entry_pairs_on_operation_id ON public.stern_entry_pairs USING btree (operation_id);


--
-- Name: index_stern_operation_attempts_on_attempted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stern_operation_attempts_on_attempted_at ON public.stern_operation_attempts USING btree (attempted_at);


--
-- Name: index_stern_operation_attempts_on_idem_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stern_operation_attempts_on_idem_key ON public.stern_operation_attempts USING btree (idem_key);


--
-- Name: index_stern_operation_attempts_on_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stern_operation_attempts_on_name ON public.stern_operation_attempts USING btree (name);


--
-- Name: index_stern_operation_attempts_on_operation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stern_operation_attempts_on_operation_id ON public.stern_operation_attempts USING btree (operation_id);


--
-- Name: index_stern_operation_attempts_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stern_operation_attempts_on_status ON public.stern_operation_attempts USING btree (status);


--
-- Name: index_stern_operations_on_idem_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_stern_operations_on_idem_key ON public.stern_operations USING btree (idem_key) WHERE (idem_key IS NOT NULL);


--
-- Name: index_stern_operations_on_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stern_operations_on_name ON public.stern_operations USING btree (name);


--
-- Name: index_stern_scheduled_operations_on_after_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stern_scheduled_operations_on_after_time ON public.stern_scheduled_operations USING btree (after_time);


--
-- Name: index_stern_scheduled_operations_on_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stern_scheduled_operations_on_name ON public.stern_scheduled_operations USING btree (name);


--
-- Name: index_stern_scheduled_operations_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stern_scheduled_operations_on_status ON public.stern_scheduled_operations USING btree (status);


--
-- Name: stern_scheduled_operations stern_sop_notify_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER stern_sop_notify_trigger AFTER INSERT OR UPDATE OF status ON public.stern_scheduled_operations FOR EACH ROW EXECUTE FUNCTION public.stern_sop_notify();


--
-- Name: stern_operation_attempts fk_rails_5a4a5cf52c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stern_operation_attempts
    ADD CONSTRAINT fk_rails_5a4a5cf52c FOREIGN KEY (operation_id) REFERENCES public.stern_operations(id) ON DELETE SET NULL;


--
-- Name: stern_entry_pairs fk_rails_6f6a4b6947; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stern_entry_pairs
    ADD CONSTRAINT fk_rails_6f6a4b6947 FOREIGN KEY (operation_id) REFERENCES public.stern_operations(id) ON DELETE RESTRICT;


--
-- Name: stern_entries fk_rails_b59e6d00a0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stern_entries
    ADD CONSTRAINT fk_rails_b59e6d00a0 FOREIGN KEY (entry_pair_id) REFERENCES public.stern_entry_pairs(id) ON DELETE RESTRICT;


--
-- PostgreSQL database dump complete
--


SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260427000000'),
('20250530090922'),
('20250530090921'),
('20250530090920');

