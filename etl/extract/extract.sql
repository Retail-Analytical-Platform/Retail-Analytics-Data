-- Install extract-stage functions.
CREATE SCHEMA IF NOT EXISTS etl;

CREATE OR REPLACE FUNCTION etl.extract()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    CREATE SCHEMA IF NOT EXISTS staging;
    DROP TABLE IF EXISTS staging.fact_sales;
    DROP TABLE IF EXISTS staging.dim_store;
    DROP TABLE IF EXISTS staging.dim_customer;
    DROP TABLE IF EXISTS staging.dim_product;
    DROP TABLE IF EXISTS staging.dim_date;

    CREATE TABLE staging.dim_date AS TABLE public.dim_date;
    CREATE TABLE staging.dim_product AS TABLE public.dim_product;
    CREATE TABLE staging.dim_customer AS TABLE public.dim_customer;
    CREATE TABLE staging.dim_store AS TABLE public.dim_store;
    CREATE TABLE staging.fact_sales AS TABLE public.fact_sales;

    CREATE TABLE IF NOT EXISTS staging.raw_sales (
        sale_id integer NOT NULL,
        category text NOT NULL
    );
    TRUNCATE staging.raw_sales;
END;
$$;

CREATE OR REPLACE FUNCTION etl.validate_raw_sales()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM staging.raw_sales) THEN
        RAISE EXCEPTION 'staging.raw_sales is empty';
    END IF;
    IF EXISTS (SELECT 1 FROM staging.raw_sales GROUP BY sale_id HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'staging.raw_sales contains duplicate sale_id values';
    END IF;
END;
$$;

-- Notebook call: SELECT etl.extract();
-- CSV import is client-side and cannot run inside PostgreSQL:
-- psql "$DATABASE_URL" -c "SELECT etl.extract();" \
--   -c "\\copy staging.raw_sales (sale_id, category) FROM '/absolute/path/raw_sales.csv' CSV HEADER" \
--   -c "SELECT etl.validate_raw_sales();"
