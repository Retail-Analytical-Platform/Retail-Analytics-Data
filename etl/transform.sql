-- transform.sql  (replaces the old file)
CREATE SCHEMA IF NOT EXISTS etl;

CREATE OR REPLACE FUNCTION etl.transform()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    src_month_bad  integer;
    src_neg_margin integer;
    mismatch_rate  numeric;
BEGIN
    -- raw_sales (CSV) is now OPTIONAL: it is only used for the category audit table.
    IF EXISTS (SELECT 1 FROM staging.raw_sales) THEN
        PERFORM etl.validate_raw_sales();
    END IF;

    CREATE SCHEMA IF NOT EXISTS transformed;
    DROP TABLE IF EXISTS transformed.category_audit;
    DROP TABLE IF EXISTS transformed.customer_duplicate_pairs;
    DROP TABLE IF EXISTS transformed.customer_review;
    DROP TABLE IF EXISTS transformed.customer_dedup_map;
    DROP TABLE IF EXISTS transformed.fact_sales;
    DROP TABLE IF EXISTS transformed.dim_store;
    DROP TABLE IF EXISTS transformed.dim_customer;
    DROP TABLE IF EXISTS transformed.dim_product;
    DROP TABLE IF EXISTS transformed.dim_date;
    DROP TABLE IF EXISTS transformed.customer_ranked;

    -- ---------------- Issue 3: dim_date ----------------
    SELECT count(*) INTO src_month_bad FROM staging.dim_date
    WHERE month_name IS DISTINCT FROM trim(to_char(full_date, 'Month'));
    RAISE NOTICE 'Issue 3: source month_name mismatches = %', src_month_bad;

    CREATE TABLE transformed.dim_date AS
    SELECT date_key, full_date, trim(to_char(full_date, 'Day')) AS day_of_week,
           trim(to_char(full_date, 'Month')) AS month_name,
           'Q' || extract(quarter FROM full_date)::int::text AS quarter,
           extract(isodow FROM full_date) IN (6, 7) AS is_weekend
    FROM staging.dim_date;

    IF EXISTS (
        SELECT 1 FROM transformed.dim_date
        WHERE array_position(ARRAY['January','February','March','April','May','June',
              'July','August','September','October','November','December'], month_name)
              IS DISTINCT FROM extract(month FROM full_date)::int
    ) THEN RAISE EXCEPTION 'month_name does not match full_date'; END IF;

    -- ------- Issues 2, 5, 9: dim_product (category map + pricing rules) -------
    SELECT count(*) INTO src_neg_margin FROM staging.dim_product WHERE unit_cost > list_price;
    RAISE NOTICE 'Issue 5: source products with unit_cost > list_price = %', src_neg_margin;

    CREATE TABLE transformed.dim_product AS
    WITH base AS (
        SELECT product_key, btrim(product_name) AS product_name, btrim(subcategory) AS subcategory
        FROM staging.dim_product
    ), cat AS (
        SELECT b.product_key, b.product_name, b.subcategory, m.category
        FROM base b LEFT JOIN etl.product_category_map m ON m.product_name = b.product_name
    ), priced AS (
        SELECT c.*, r.unit_cost, r.list_price, r.rule_id AS pricing_rule_id
        FROM cat c
        LEFT JOIN LATERAL (
            SELECT x.* FROM etl.pricing_rules x
            WHERE x.category = c.category AND c.product_name ILIKE x.name_pattern
            ORDER BY length(x.name_pattern) DESC, x.rule_id LIMIT 1
        ) r ON true
    )
    SELECT product_key, product_name, category, subcategory, unit_cost, list_price,
           unit_cost > list_price AS cost_gt_price,
           round((list_price - unit_cost) / nullif(list_price, 0) * 100, 2) AS margin_pct,
           pricing_rule_id
    FROM priced;

    IF EXISTS (SELECT 1 FROM transformed.dim_product WHERE category IS NULL) THEN
        RAISE EXCEPTION 'product without a category: add it to etl.product_category_map';
    END IF;
    IF EXISTS (SELECT 1 FROM transformed.dim_product WHERE pricing_rule_id IS NULL) THEN
        RAISE EXCEPTION 'product without a pricing rule: add it to etl.pricing_rules';
    END IF;
    IF EXISTS (SELECT 1 FROM transformed.dim_product WHERE cost_gt_price) THEN
        RAISE EXCEPTION 'negative-margin products remain after applying pricing rules';
    END IF;

    -- ---------------- Issue 6: customers ----------------
    CREATE TABLE transformed.customer_ranked AS
    WITH order_counts AS (
        SELECT customer_key, count(*) AS n_orders FROM staging.fact_sales GROUP BY customer_key
    ), normalized AS (
        SELECT c.customer_key, btrim(c.customer_name) AS customer_name,
               nullif(lower(btrim(c.email)), '') AS email,
               btrim(c.city) AS city, upper(btrim(c.country)) AS country, c.segment,
               coalesce(o.n_orders, 0) AS n_orders,
               lower(btrim(c.customer_name)) AS name_norm,
               (c.customer_name IS NOT NULL)::int + (c.city IS NOT NULL)::int
                 + (c.country IS NOT NULL)::int + (c.segment IS NOT NULL)::int AS completeness
        FROM staging.dim_customer c LEFT JOIN order_counts o USING (customer_key)
    )
    SELECT *, first_value(customer_key) OVER (
        -- duplicate = same email AND same name; a NULL email/name never merges anyone
        PARTITION BY coalesce(email || '|' || name_norm, '#' || customer_key::text)
        ORDER BY n_orders DESC, completeness DESC, customer_key
    ) AS survivor_key
    FROM normalized;

    CREATE TABLE transformed.customer_dedup_map AS
    SELECT customer_key AS loser_key, survivor_key
    FROM transformed.customer_ranked WHERE customer_key <> survivor_key;

    CREATE TABLE transformed.customer_duplicate_pairs AS
    SELECT a.email, a.customer_key AS key_a, b.customer_key AS key_b,
           a.name_norm IS NOT DISTINCT FROM b.name_norm AS same_name,
           a.city      IS NOT DISTINCT FROM b.city      AS same_city,
           a.country   IS NOT DISTINCT FROM b.country   AS same_country,
           a.segment   IS NOT DISTINCT FROM b.segment   AS same_segment,
           a.n_orders AS orders_a, b.n_orders AS orders_b,
           a.survivor_key = b.survivor_key AS merged
    FROM transformed.customer_ranked a
    JOIN transformed.customer_ranked b ON a.email = b.email AND a.customer_key < b.customer_key;

    CREATE TABLE transformed.customer_review AS      -- same email, different names: NOT merged
    SELECT customer_key, customer_name, email
    FROM transformed.customer_ranked
    WHERE email IN (SELECT email FROM transformed.customer_ranked WHERE email IS NOT NULL
                    GROUP BY email HAVING count(DISTINCT name_norm) > 1)
    ORDER BY email, customer_key;

    CREATE TABLE transformed.dim_customer AS
    SELECT customer_key, customer_name, email, city, country, segment
    FROM transformed.customer_ranked WHERE customer_key = survivor_key;

    CREATE TABLE transformed.dim_store AS TABLE staging.dim_store;

    -- ------ Issues 1, 7, 8: fact_sales (Option B: category derived from dim_product) ------
    CREATE TABLE transformed.fact_sales AS
    WITH qrule AS (
        SELECT p.product_key, r.quantity_basis,
               CASE WHEN r.quantity_basis = 'pack' THEN r.units_per_pack ELSE 1 END AS mult
        FROM transformed.dim_product p
        LEFT JOIN LATERAL (
            SELECT q.* FROM etl.quantity_rules q
            WHERE q.category = p.category AND p.product_name ILIKE q.name_pattern
            ORDER BY length(q.name_pattern) DESC, q.rule_id LIMIT 1
        ) r ON true
    )
    SELECT f.sale_id, f.date_key, f.product_key,
           coalesce(m.survivor_key, f.customer_key) AS customer_key,
           f.store_key, f.sold_at, f.quantity, f.unit_price, f.discount_pct,
           f.revenue,
           p.category,                                                     -- Issue 8: lookup
           q.quantity_basis,                                               -- Issue 1
           f.quantity * q.mult AS units_sold,
           f.quantity = max(f.quantity) OVER () AS qty_at_max,
           round(f.quantity * f.unit_price * (1 - f.discount_pct), 2) AS revenue_expected,  -- Issue 7
           abs(f.revenue - round(f.quantity * f.unit_price * (1 - f.discount_pct), 2)) > 0.05
               AS revenue_mismatch
    FROM staging.fact_sales f
    JOIN transformed.dim_product p ON p.product_key = f.product_key
    JOIN qrule q ON q.product_key = f.product_key
    LEFT JOIN transformed.customer_dedup_map m ON m.loser_key = f.customer_key;

    -- optional audit against the original CSV category (empty if raw_sales was not loaded)
    CREATE TABLE transformed.category_audit AS
    SELECT f.sale_id, btrim(r.category) AS category_original, f.category AS category_derived,
           btrim(r.category) IS NOT DISTINCT FROM f.category AS matches
    FROM transformed.fact_sales f LEFT JOIN staging.raw_sales r USING (sale_id);

    -- ---------------- quality gates ----------------
    IF (SELECT count(*) FROM transformed.fact_sales) <> (SELECT count(*) FROM staging.fact_sales) THEN
        RAISE EXCEPTION 'fact_sales row count changed (check product_key / quantity rules)';
    END IF;
    IF EXISTS (SELECT 1 FROM transformed.fact_sales GROUP BY sale_id HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'duplicate sale_id in fact_sales';
    END IF;
    IF EXISTS (SELECT 1 FROM transformed.fact_sales WHERE quantity_basis IS NULL) THEN
        RAISE EXCEPTION 'sales rows without a quantity rule';
    END IF;
    IF EXISTS (SELECT 1 FROM transformed.fact_sales f LEFT JOIN transformed.dim_date d USING (date_key) WHERE d.date_key IS NULL)
       OR EXISTS (SELECT 1 FROM transformed.fact_sales f LEFT JOIN transformed.dim_product d USING (product_key) WHERE d.product_key IS NULL)
       OR EXISTS (SELECT 1 FROM transformed.fact_sales f LEFT JOIN transformed.dim_customer d USING (customer_key) WHERE d.customer_key IS NULL)
       OR EXISTS (SELECT 1 FROM transformed.fact_sales f LEFT JOIN transformed.dim_store d USING (store_key) WHERE d.store_key IS NULL) THEN
        RAISE EXCEPTION 'fact_sales has orphan dimension keys';
    END IF;
    IF EXISTS (SELECT 1 FROM transformed.dim_customer WHERE email IS NOT NULL
               GROUP BY email, lower(customer_name) HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'duplicate customers (same email + name) remain';
    END IF;
    IF EXISTS (SELECT 1 FROM transformed.fact_sales f JOIN transformed.dim_product p USING (product_key)
               WHERE f.category IS DISTINCT FROM p.category) THEN
        RAISE EXCEPTION 'fact_sales.category differs from dim_product.category';
    END IF;

    SELECT round(100.0 * count(*) FILTER (WHERE revenue_mismatch) / count(*), 2)
      INTO mismatch_rate FROM transformed.fact_sales;
    RAISE NOTICE 'Issue 7: stored revenue differs from the standard formula on % percent of rows', mismatch_rate;

    DROP TABLE transformed.customer_ranked;
END;
$$;

-- Notebook call: SELECT etl.transform();