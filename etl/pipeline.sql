-- Full ETL pipeline orchestrator (replaces previous version)
-- Runs rules, extract, transform, load and applies notebook migrations
CREATE SCHEMA IF NOT EXISTS etl;

\set ON_ERROR_STOP on
\set script_dir `pwd`/etl

\i :script_dir/rules.sql
\i :script_dir/extract.sql
\i :script_dir/transform.sql
\i :script_dir/load.sql

-- Apply notebook/main_pipeline migrations
SELECT etl.transform_notebook();
SELECT etl.load_notebook();

CREATE OR REPLACE FUNCTION etl.run_pipeline()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM etl.transform();
    PERFORM etl.load();
    PERFORM etl.transform_notebook();
    PERFORM etl.load_notebook();
END;
$$;
