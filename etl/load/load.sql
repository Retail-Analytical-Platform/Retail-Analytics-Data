-- Install the load-stage function.
CREATE SCHEMA IF NOT EXISTS etl;

CREATE OR REPLACE FUNCTION etl.load()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF to_regclass('transformed.fact_sales') IS NULL THEN
        RAISE EXCEPTION 'transformed.fact_sales does not exist; run etl.transform() first';
    END IF;

    CREATE SCHEMA IF NOT EXISTS clean;
    DROP TABLE IF EXISTS clean.customer_review;
    DROP TABLE IF EXISTS clean.customer_dedup_map;
    DROP TABLE IF EXISTS clean.fact_sales;
    DROP TABLE IF EXISTS clean.dim_store;
    DROP TABLE IF EXISTS clean.dim_customer;
    DROP TABLE IF EXISTS clean.dim_product;
    DROP TABLE IF EXISTS clean.dim_date;

    CREATE TABLE clean.dim_date AS TABLE transformed.dim_date;
    ALTER TABLE clean.dim_date ADD PRIMARY KEY (date_key);
    CREATE TABLE clean.dim_product AS TABLE transformed.dim_product;
    ALTER TABLE clean.dim_product ADD PRIMARY KEY (product_key);
    CREATE TABLE clean.dim_customer AS TABLE transformed.dim_customer;
    ALTER TABLE clean.dim_customer ADD PRIMARY KEY (customer_key);
    CREATE TABLE clean.dim_store AS TABLE transformed.dim_store;
    ALTER TABLE clean.dim_store ADD PRIMARY KEY (store_key);
    CREATE TABLE clean.fact_sales AS TABLE transformed.fact_sales;
    ALTER TABLE clean.fact_sales ADD PRIMARY KEY (sale_id);
    CREATE TABLE clean.customer_dedup_map AS TABLE transformed.customer_dedup_map;
    CREATE TABLE clean.customer_review AS TABLE transformed.customer_review;

    ALTER TABLE clean.fact_sales ADD FOREIGN KEY (date_key) REFERENCES clean.dim_date(date_key);
    ALTER TABLE clean.fact_sales ADD FOREIGN KEY (product_key) REFERENCES clean.dim_product(product_key);
    ALTER TABLE clean.fact_sales ADD FOREIGN KEY (customer_key) REFERENCES clean.dim_customer(customer_key);
    ALTER TABLE clean.fact_sales ADD FOREIGN KEY (store_key) REFERENCES clean.dim_store(store_key);
END;
$$;

-- Notebook call: SELECT etl.load();
