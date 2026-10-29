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
DECLARE
    raw_n   integer;
    fact_n  integer;
    phantom integer;
BEGIN
    SELECT count(*) INTO raw_n FROM staging.raw_sales;
    IF raw_n = 0 THEN
        RAISE EXCEPTION 'staging.raw_sales is empty';
    END IF;
    IF EXISTS (SELECT 1 FROM staging.raw_sales GROUP BY sale_id HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'staging.raw_sales contains duplicate sale_id values';
    END IF;

    SELECT count(*) INTO phantom FROM staging.raw_sales r
    WHERE NOT EXISTS (SELECT 1 FROM staging.fact_sales f WHERE f.sale_id = r.sale_id);
    IF phantom > 0 THEN
        RAISE EXCEPTION 'staging.raw_sales has % sale_id value(s) not present in staging.fact_sales', phantom;
    END IF;

    SELECT count(*) INTO fact_n FROM staging.fact_sales;
    IF raw_n <> fact_n THEN
        RAISE EXCEPTION 'staging.raw_sales has % rows but staging.fact_sales has % rows', raw_n, fact_n;
    END IF;
END;
$$;