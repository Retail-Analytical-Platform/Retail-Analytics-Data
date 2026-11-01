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
END;
$$;