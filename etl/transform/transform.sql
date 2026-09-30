-- Install the transform-stage function.
CREATE SCHEMA IF NOT EXISTS etl;

CREATE OR REPLACE FUNCTION etl.transform()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    category_count integer;
    bad_distribution boolean;
BEGIN
    PERFORM etl.validate_raw_sales();
    CREATE SCHEMA IF NOT EXISTS transformed;
    DROP TABLE IF EXISTS transformed.customer_review;
    DROP TABLE IF EXISTS transformed.customer_dedup_map;
    DROP TABLE IF EXISTS transformed.fact_sales;
    DROP TABLE IF EXISTS transformed.dim_store;
    DROP TABLE IF EXISTS transformed.dim_customer;
    DROP TABLE IF EXISTS transformed.dim_product;
    DROP TABLE IF EXISTS transformed.dim_date;
    DROP TABLE IF EXISTS transformed.customer_ranked;

    CREATE TABLE transformed.dim_date AS
    SELECT date_key, full_date, trim(to_char(full_date, 'Day')) AS day_of_week,
           trim(to_char(full_date, 'Month')) AS month_name,
           'Q' || extract(quarter FROM full_date)::text AS quarter,
           extract(isodow FROM full_date) IN (6, 7) AS is_weekend
    FROM staging.dim_date;

    CREATE TABLE transformed.dim_product AS
    SELECT product_key, btrim(product_name) AS product_name,
           btrim(category) AS category, btrim(subcategory) AS subcategory,
           unit_cost, list_price, unit_cost > list_price AS cost_gt_price
    FROM staging.dim_product;

    CREATE TABLE transformed.customer_ranked AS
    WITH order_counts AS (
        SELECT customer_key, count(*) AS n_orders FROM staging.fact_sales GROUP BY customer_key
    ), normalized AS (
        SELECT c.customer_key, btrim(c.customer_name) AS customer_name,
               lower(btrim(c.email)) AS email, btrim(c.city) AS city,
               upper(btrim(c.country)) AS country, c.segment,
               coalesce(o.n_orders, 0) AS n_orders,
               lower(btrim(c.customer_name)) AS name_norm
        FROM staging.dim_customer c LEFT JOIN order_counts o USING (customer_key)
    )
    SELECT *, first_value(customer_key) OVER (
        PARTITION BY email, name_norm ORDER BY n_orders DESC, customer_key
    ) AS survivor_key
    FROM normalized;

    CREATE TABLE transformed.customer_dedup_map AS
    SELECT customer_key AS loser_key, survivor_key
    FROM transformed.customer_ranked WHERE customer_key <> survivor_key;

    CREATE TABLE transformed.customer_review AS
    SELECT customer_key, customer_name, email
    FROM transformed.customer_ranked
    WHERE email IN (
        SELECT email FROM transformed.customer_ranked
        GROUP BY email HAVING count(DISTINCT name_norm) > 1
    )
    ORDER BY email, customer_key;

    CREATE TABLE transformed.dim_customer AS
    SELECT customer_key, customer_name, email, city, country, segment
    FROM transformed.customer_ranked WHERE customer_key = survivor_key;
    CREATE TABLE transformed.dim_store AS TABLE staging.dim_store;

    CREATE TABLE transformed.fact_sales AS
    SELECT f.sale_id, f.date_key, f.product_key,
           coalesce(m.survivor_key, f.customer_key) AS customer_key,
           f.store_key, f.sold_at, f.quantity, f.unit_price, f.discount_pct,
           f.revenue, btrim(r.category) AS category,
           round(f.quantity * f.unit_price * (1 - f.discount_pct), 2) AS revenue_expected,
           abs(f.revenue - round(f.quantity * f.unit_price * (1 - f.discount_pct), 2)) > 0.05
               AS revenue_mismatch
    FROM staging.fact_sales f
    JOIN staging.raw_sales r USING (sale_id)
    LEFT JOIN transformed.customer_dedup_map m ON m.loser_key = f.customer_key;

    IF (SELECT count(*) FROM transformed.fact_sales) <> (SELECT count(*) FROM staging.fact_sales) THEN
        RAISE EXCEPTION 'some fact_sales rows have no match in staging.raw_sales';
    END IF;
    IF EXISTS (SELECT 1 FROM transformed.fact_sales GROUP BY sale_id HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'duplicate sale_id in fact_sales';
    END IF;
    IF EXISTS (SELECT 1 FROM transformed.fact_sales f LEFT JOIN transformed.dim_date d USING (date_key) WHERE d.date_key IS NULL)
       OR EXISTS (SELECT 1 FROM transformed.fact_sales f LEFT JOIN transformed.dim_product d USING (product_key) WHERE d.product_key IS NULL)
       OR EXISTS (SELECT 1 FROM transformed.fact_sales f LEFT JOIN transformed.dim_customer d USING (customer_key) WHERE d.customer_key IS NULL)
       OR EXISTS (SELECT 1 FROM transformed.fact_sales f LEFT JOIN transformed.dim_store d USING (store_key) WHERE d.store_key IS NULL) THEN
        RAISE EXCEPTION 'fact_sales has orphan dimension keys';
    END IF;

    SELECT count(*) INTO category_count FROM (SELECT DISTINCT category FROM transformed.fact_sales) categories;
    SELECT count(*) <> 4 OR bool_or(abs(pct - expected_pct) > 0.5) INTO bad_distribution
    FROM (
        SELECT 100.0 * count(*) / sum(count(*)) OVER () AS pct,
               row_number() OVER (ORDER BY count(*) DESC) AS rn
        FROM transformed.fact_sales GROUP BY category
    ) actual
    JOIN (VALUES (1, 42.0), (2, 26.0), (3, 20.0), (4, 12.0)) expected(rn, expected_pct)
        USING (rn);
    IF category_count <> 4 OR coalesce(bad_distribution, true) THEN
        RAISE EXCEPTION 'category distribution differs from expected 42/26/20/12 percent';
    END IF;

    DROP TABLE transformed.customer_ranked;
END;
$$;

-- Notebook call: SELECT etl.transform();
