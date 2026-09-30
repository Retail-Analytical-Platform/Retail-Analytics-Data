-- Step 3: Publish validated transformed tables to the clean schema.
-- Run after etl/transform/transform.sql.
\set ON_ERROR_STOP on

BEGIN;
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

ALTER TABLE clean.fact_sales ADD CONSTRAINT fact_sales_date_key_fkey
    FOREIGN KEY (date_key) REFERENCES clean.dim_date(date_key);
ALTER TABLE clean.fact_sales ADD CONSTRAINT fact_sales_product_key_fkey
    FOREIGN KEY (product_key) REFERENCES clean.dim_product(product_key);
ALTER TABLE clean.fact_sales ADD CONSTRAINT fact_sales_customer_key_fkey
    FOREIGN KEY (customer_key) REFERENCES clean.dim_customer(customer_key);
ALTER TABLE clean.fact_sales ADD CONSTRAINT fact_sales_store_key_fkey
    FOREIGN KEY (store_key) REFERENCES clean.dim_store(store_key);
COMMIT;

SELECT 'dim_date' AS table_name, count(*) AS rows FROM clean.dim_date
UNION ALL SELECT 'dim_product', count(*) FROM clean.dim_product
UNION ALL SELECT 'dim_customer', count(*) FROM clean.dim_customer
UNION ALL SELECT 'dim_store', count(*) FROM clean.dim_store
UNION ALL SELECT 'fact_sales', count(*) FROM clean.fact_sales
ORDER BY table_name;

SELECT category, count(*) AS rows,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS pct
FROM clean.fact_sales GROUP BY category ORDER BY pct DESC;
