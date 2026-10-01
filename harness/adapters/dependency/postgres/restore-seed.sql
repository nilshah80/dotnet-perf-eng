-- Restore the seeded dataset before a run (postgres reset adapter).
--
-- The lab apps seed only an empty database, at startup. Rows a write scenario
-- adds or changes therefore survived into every later run: after E07 the
-- ecommerce catalogue held 282,827 products instead of 20,000, and
-- browse-and-buy's search averaged 104 ms instead of ~5 ms.
--
-- The first reset on a fresh volume copies every public table into the
-- harness-owned perflab_seed schema; the app reports ready only after seeding,
-- so that copy is the seed. Every later reset truncates the public tables and
-- reloads them from it, which also undoes UPDATEs (E08, S10, S27), and realigns
-- identity sequences. `compose down -v` (as run-data-scale.sh does per scale)
-- drops the snapshot with the volume, so a new scale gets a new snapshot.
SET lock_timeout = '30s';
DO $$
DECLARE
  t record;
  sq record;
  cols text;
  tables text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'perflab_seed') THEN
    CREATE SCHEMA perflab_seed;
    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename LOOP
      EXECUTE format('CREATE TABLE perflab_seed.%I AS TABLE public.%I', t.tablename, t.tablename);
    END LOOP;
    RAISE NOTICE 'perflab_seed snapshot created';
    RETURN;
  END IF;

  SELECT string_agg(format('public.%I', p.tablename), ', ' ORDER BY p.tablename) INTO tables
  FROM pg_tables p
  JOIN pg_tables s ON s.schemaname = 'perflab_seed' AND s.tablename = p.tablename
  WHERE p.schemaname = 'public';
  IF tables IS NULL THEN
    RETURN;
  END IF;
  -- Reload in any order: foreign-key triggers are suspended for this transaction.
  PERFORM set_config('session_replication_role', 'replica', true);
  EXECUTE 'TRUNCATE ' || tables || ' RESTART IDENTITY CASCADE';
  FOR t IN SELECT s.tablename FROM pg_tables s
           JOIN pg_tables p ON p.schemaname = 'public' AND p.tablename = s.tablename
           WHERE s.schemaname = 'perflab_seed' ORDER BY s.tablename LOOP
    SELECT string_agg(format('%I', column_name), ', ' ORDER BY ordinal_position) INTO cols
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = t.tablename AND is_generated = 'NEVER';
    EXECUTE format('INSERT INTO public.%I (%s) OVERRIDING SYSTEM VALUE SELECT %s FROM perflab_seed.%I',
                   t.tablename, cols, cols, t.tablename);
  END LOOP;
  FOR sq IN SELECT c.table_name, c.column_name,
                  pg_get_serial_sequence(format('public.%I', c.table_name), c.column_name) AS seq
           FROM information_schema.columns c
           WHERE c.table_schema = 'public'
             AND pg_get_serial_sequence(format('public.%I', c.table_name), c.column_name) IS NOT NULL LOOP
    EXECUTE format('SELECT setval(%L, COALESCE((SELECT max(%I) FROM public.%I), 0) + 1, false)',
                   sq.seq, sq.column_name, sq.table_name);
  END LOOP;
END $$;
