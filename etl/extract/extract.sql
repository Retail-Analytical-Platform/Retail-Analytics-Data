-- Step 1: Extract source tables into the staging schema.
-- Run with psql. Example:
-- psql "$DATABASE_URL" -v raw_sales_csv=/absolute/path/raw_sales.csv -f etl/extract/extract.sql
\set ON_ERROR_STOP on

BEGIN;

CREATE SCHEMA IF NOT EXISTS staging;
DROP TABLE IF EXISTS staging.raw_sales;
DROP TABLE IF EXISTS staging.fact_sales;
DROP TABLE IF EXISTS staging.dim_store;
DROP TABLE IF EXISTS staging.dim_customer;
DROP TABLE IF EXISTS staging.dim_product;
DROP TABLE IF EXISTS staging.dim_date;

CREATE TABLE staging.dim_date     AS TABLE public.dim_date;
CREATE TABLE staging.dim_product  AS TABLE public.dim_product;
CREATE TABLE staging.dim_customer AS TABLE public.dim_customer;
CREATE TABLE staging.dim_store    AS TABLE public.dim_store;
CREATE TABLE staging.fact_sales   AS TABLE public.fact_sales;

CREATE TABLE staging.raw_sales (
    sale_id  integer NOT NULL,
    category text NOT NULL
);
COMMIT;

-- \copy is a psql command (not server-side COPY), so the CSV is read from the
-- machine running psql. raw_sales_csv must be provided as shown above.
\if :{?raw_sales_csv}
  \copy staging.raw_sales (sale_id, category) FROM :'raw_sales_csv' WITH (FORMAT csv, HEADER true)
\else
  \echo 'ERROR: pass -v raw_sales_csv=/absolute/path/raw_sales.csv'
  \quit
\endif

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM staging.raw_sales GROUP BY sale_id HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'raw_sales contains duplicate sale_id values';
    END IF;
END $$;
