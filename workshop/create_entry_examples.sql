--
-- Create entry records.
--
DELETE FROM stern_entries;

SELECT * FROM create_entry(1, 1101, 99, 9500, verbose_mode := TRUE);
SELECT * FROM create_entry(1, 1101, 100, 7500, verbose_mode := TRUE);
SELECT * FROM create_entry(1, 1101, 101, 9900, verbose_mode := TRUE);

SELECT * FROM create_entry(1, 1101, 96, -1500, (
  SELECT timestamp
  FROM stern_entries
  ORDER BY book_id, gid, timestamp DESC
  LIMIT 1
) - INTERVAL '1 milliseconds',
verbose_mode := TRUE);

SELECT * FROM create_entry(1, 1101, 110, 6500, '2023-04-07 21:11:29.206489-03', verbose_mode := TRUE);
SELECT * FROM create_entry(1, 1101, 111, 6500, '2023-04-07 21:11:28.206488-03', verbose_mode := TRUE);
SELECT * FROM create_entry(1, 1101, 112, 6500, '2023-04-06 21:38:00.011001-03', verbose_mode := TRUE);
SELECT * FROM create_entry(1, 1101, 113, 6500, '2023-04-08 00:12:00.011000+00', verbose_mode := TRUE);
SELECT * FROM create_entry(1, 1101, 114, 6500, '2023-04-08 00:12:00.011000', verbose_mode := TRUE);

SELECT * FROM stern_entries ORDER BY book_id, gid, timestamp;


SELECT * FROM create_entry(1, 1101, 10, 5000, verbose_mode := TRUE);
