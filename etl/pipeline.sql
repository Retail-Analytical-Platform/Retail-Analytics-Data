<<<<<<< Updated upstream
-- Install this after extract/extract.sql, transform/transform.sql, and load/load.sql.
-- raw_sales must already be loaded into staging.raw_sales.
=======
-- Full ETL pipeline orchestrator.
-- Extraction and raw_sales loading are performed by etl/run_etl.sh.
>>>>>>> Stashed changes
CREATE SCHEMA IF NOT EXISTS etl;

CREATE OR REPLACE FUNCTION etl.run_pipeline()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM etl.transform();
    PERFORM etl.load();
<<<<<<< Updated upstream
=======
    PERFORM etl.apply_notebook_transform();
    PERFORM etl.apply_notebook_load();
>>>>>>> Stashed changes
END;
$$;

-- Notebook call: SELECT etl.run_pipeline();

