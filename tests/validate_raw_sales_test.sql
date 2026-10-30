-- Regression tests for etl.validate_raw_sales() (issue #66).
-- Run: psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/validate_raw_sales_test.sql
-- Everything runs in one transaction that is rolled back.
BEGIN;
SELECT etl.extract();

-- 1. A sale_id that does not exist in staging.fact_sales must be rejected.
DO $$
BEGIN
    TRUNCATE staging.raw_sales;
    INSERT INTO staging.raw_sales VALUES (999999, 'x');
    BEGIN
        PERFORM etl.validate_raw_sales();
    EXCEPTION WHEN raise_exception THEN
        RETURN;
    END;
    RAISE EXCEPTION 'TEST FAILED: phantom sale_id was accepted';
END $$;

-- 2. Partial coverage (3 rows instead of all) must be rejected.
DO $$
BEGIN
    TRUNCATE staging.raw_sales;
    INSERT INTO staging.raw_sales SELECT sale_id, category FROM staging.fact_sales LIMIT 3;
    BEGIN
        PERFORM etl.validate_raw_sales();
    EXCEPTION WHEN raise_exception THEN
        RETURN;
    END;
    RAISE EXCEPTION 'TEST FAILED: partial coverage was accepted';
END $$;

-- 3. A full, matching load must pass.
DO $$
BEGIN
    TRUNCATE staging.raw_sales;
    INSERT INTO staging.raw_sales SELECT sale_id, category FROM staging.fact_sales;
    PERFORM etl.validate_raw_sales();
END $$;

ROLLBACK;
\echo 'validate_raw_sales tests passed'
