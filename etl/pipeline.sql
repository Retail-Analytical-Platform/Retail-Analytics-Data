-- Full ETL pipeline orchestrator.
-- etl.extract() must be run first (etl/run_etl.sh and the GitHub workflow do this).
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