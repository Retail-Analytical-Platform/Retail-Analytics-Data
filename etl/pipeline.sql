-- Full ETL pipeline orchestrator.
-- Extraction and raw_sales loading are performed by etl/run_etl.sh.
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

