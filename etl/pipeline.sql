-- Install this after extract/extract.sql, transform/transform.sql, and load/load.sql.
-- raw_sales must already be loaded into staging.raw_sales.
CREATE SCHEMA IF NOT EXISTS etl;

CREATE OR REPLACE FUNCTION etl.run_pipeline()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM etl.transform();
    PERFORM etl.load();
END;
$$;

-- Notebook call: SELECT etl.run_pipeline();

