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
    gid integer NOT NULL,
    entry_pair_id bigint NOT NULL,
    amount bigint NOT NULL,
    ending_balance bigint NOT NULL,
    "timestamp" timestamp(6) without time zone NOT NULL
);


--
-- Name: create_entry(integer, integer, bigint, bigint, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_entry(in_book_id integer, in_gid integer, in_entry_pair_id bigint, in_amount bigint, in_timestamp_utc timestamp without time zone DEFAULT NULL::timestamp without time zone, verbose_mode boolean DEFAULT false) RETURNS public.stern_entries
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: destroy_entry(bigint, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.destroy_entry(in_id bigint, verbose_mode boolean DEFAULT false) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
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
-- Name: credit_entry_pair_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.credit_entry_pair_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: gid_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.gid_seq
    START WITH 1201
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


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
    name character varying NOT NULL
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
    credit_entry_pair_id bigint,
    operation_id bigint NOT NULL
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
-- Name: stern_operations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stern_operations (
    id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    name character varying NOT NULL,
    direction integer NOT NULL,
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
    error_message character varying
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

CREATE INDEX index_stern_books_on_name ON public.stern_books USING btree (name);


--
-- Name: index_stern_entries_on_book_id_and_gid_and_entry_pair_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_stern_entries_on_book_id_and_gid_and_entry_pair_id ON public.stern_entries USING btree (book_id, gid, entry_pair_id);


--
-- Name: index_stern_entries_on_book_id_and_gid_and_timestamp; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_stern_entries_on_book_id_and_gid_and_timestamp ON public.stern_entries USING btree (book_id, gid, "timestamp");


--
-- Name: index_stern_entry_pairs_on_code_and_uid; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_stern_entry_pairs_on_code_and_uid ON public.stern_entry_pairs USING btree (code, uid);


--
-- Name: index_stern_entry_pairs_on_operation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stern_entry_pairs_on_operation_id ON public.stern_entry_pairs USING btree (operation_id);


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
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20250530090922'),
('20250530090921'),
('20250530090920'),
('20230524123950'),
('20230522052219'),
('20230408022903'),
('20230407233646'),
('20230402223428'),
('20230402001735'),
('20230326215510'),
('20230326215052'),
('20230326212250');

