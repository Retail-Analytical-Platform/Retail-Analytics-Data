-- transform.sql  (Option A: fact_sales keeps its ORIGINAL 4 categories, 42/26/20/12)
CREATE SCHEMA IF NOT EXISTS etl;

CREATE OR REPLACE FUNCTION etl.transform()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    src_month_bad  integer;
    src_neg_margin integer;
    mismatch_rate  numeric;
    category_count integer;
    bad_distribution boolean;
    cat_match_pct  numeric;
BEGIN
    -- raw_sales (CSV) = authoritative original category. If it is not loaded, staging.fact_sales.category is used.
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
        SELECT product_key, btrim(product_name) AS product_name,
               btrim(category) AS category, btrim(subcategory) AS subcategory
        FROM staging.dim_product
    ), cat AS (
        -- category = original 4-value label (kept as is); product_group = corrected by product name
        SELECT b.product_key, b.product_name, b.category, b.subcategory, m.category AS product_group
        FROM base b LEFT JOIN etl.product_category_map m ON m.product_name = b.product_name
    ), priced AS (
        SELECT c.*, r.unit_cost, r.list_price, r.rule_id AS pricing_rule_id
        FROM cat c
        LEFT JOIN LATERAL (
            SELECT x.* FROM etl.pricing_rules x
            WHERE x.category = c.product_group AND c.product_name ILIKE x.name_pattern
            ORDER BY length(x.name_pattern) DESC, x.rule_id LIMIT 1
        ) r ON true
    )
    SELECT product_key, product_name, category, product_group, subcategory, unit_cost, list_price,
           unit_cost > list_price AS cost_gt_price,
           round((list_price - unit_cost) / nullif(list_price, 0) * 100, 2) AS margin_pct,
           pricing_rule_id
    FROM priced;

    IF EXISTS (SELECT 1 FROM transformed.dim_product WHERE product_group IS NULL) THEN
        RAISE EXCEPTION 'product without a product_group: add it to etl.product_category_map';
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

    -- ------ Issues 1, 2, 7: fact_sales (category = original sale category) ------
    CREATE TABLE transformed.fact_sales AS
    WITH qrule AS (
        SELECT p.product_key, r.quantity_basis,
               CASE WHEN r.quantity_basis = 'pack' THEN r.units_per_pack ELSE 1 END AS mult
        FROM transformed.dim_product p
        LEFT JOIN LATERAL (
            SELECT q.* FROM etl.quantity_rules q
            WHERE q.category = p.product_group AND p.product_name ILIKE q.name_pattern
            ORDER BY length(q.name_pattern) DESC, q.rule_id LIMIT 1
        ) r ON true
    )
    SELECT f.sale_id, f.date_key, f.product_key,
           coalesce(m.survivor_key, f.customer_key) AS customer_key,
           f.store_key, f.sold_at, f.quantity, f.unit_price, f.discount_pct,
           f.revenue,
           coalesce(btrim(r.category), btrim(f.category)) AS category,     -- Issue 2: original category
           p.category IS NOT DISTINCT FROM coalesce(btrim(r.category), btrim(f.category))
               AS category_matches_product,
           q.quantity_basis,                                               -- Issue 1
           f.quantity * q.mult AS units_sold,
           f.quantity = max(f.quantity) OVER () AS qty_at_max,
           round(f.quantity * f.unit_price * (1 - f.discount_pct), 2) AS revenue_expected,  -- Issue 7
           abs(f.revenue - round(f.quantity * f.unit_price * (1 - f.discount_pct), 2)) > 0.05
               AS revenue_mismatch
    FROM staging.fact_sales f
    JOIN transformed.dim_product p ON p.product_key = f.product_key
    JOIN qrule q ON q.product_key = f.product_key
    LEFT JOIN staging.raw_sales r ON r.sale_id = f.sale_id
    LEFT JOIN transformed.customer_dedup_map m ON m.loser_key = f.customer_key;

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

    SELECT round(100.0 * count(*) FILTER (WHERE category_matches_product) / count(*), 1)
      INTO cat_match_pct FROM transformed.fact_sales;
    RAISE NOTICE 'Issue 8: sale category equals product category on % percent of rows', cat_match_pct;

    SELECT round(100.0 * count(*) FILTER (WHERE revenue_mismatch) / count(*), 2)
      INTO mismatch_rate FROM transformed.fact_sales;
    RAISE NOTICE 'Issue 7: stored revenue differs from the standard formula on % percent of rows', mismatch_rate;

    DROP TABLE transformed.customer_ranked;
END;
$$;

<<<<<<< Updated upstream
-- Notebook call: SELECT etl.transform();
=======
-- Notebook-derived transformations applied to clean tables after the base load.
CREATE OR REPLACE FUNCTION etl.apply_notebook_transform()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE clean.fact_sales f
    SET category = p.category
    FROM clean.dim_product p
    WHERE p.product_key = f.product_key;

    UPDATE clean.dim_product p
    SET product_name = b.brand || ' ' || p.product_name
    FROM public.brand_data b
    WHERE b.brand IS NOT NULL
      AND b.brand <> 'Non Brand'
      AND p.product_name LIKE '% ' || b.base_name
      AND NOT EXISTS (
          SELECT 1 FROM public.brand_data x
          WHERE x.brand IS NOT NULL AND x.brand <> 'Non Brand'
            AND p.product_name LIKE x.brand || ' %'
      );

    UPDATE clean.dim_product p
    SET unit_cost = round(p.list_price * (b.ratio_low + b.ratio_high) / 2.0, 2)
    FROM public.ref_cost_benchmark b
    WHERE b.category = p.category
      AND b.subcategory = p.subcategory
      AND p.list_price IS NOT NULL;
END;
$$;

/* Notebook migrations are intentionally excluded from the Docker ETL path.
   They mutate the public source schema and are not part of the staged
   transform contract.
CREATE TABLE IF NOT EXISTS public.brand_data (
    base_name text,
    brand text,
    ebay_matches integer,
    n_used integer,
    price numeric(12,2),
    low numeric(12,2),
    high numeric(12,2)
);

ALTER TABLE public.dim_product ADD COLUMN IF NOT EXISTS category text;

DO $$
BEGIN
    IF to_regclass('clean.dim_product') IS NOT NULL THEN
        UPDATE public.dim_product AS t SET category = s.product_group
        FROM clean.dim_product AS s WHERE t.product_key = s.product_key AND t.category IS NULL;
    END IF;
END $$;

UPDATE public.fact_sales AS fs SET category = dp.category
FROM public.dim_product AS dp WHERE fs.product_key = dp.product_key AND fs.category IS NULL;

UPDATE public.dim_product d
SET product_name = (ARRAY[
    'Sony','Samsung','LG','Philips','Apple','Xiaomi','Bose','JBL','Anker','Logitech',
    'Dell','ASUS','Lenovo','Huawei','Panasonic','Sharp','Toshiba','Hisense','TCL','Dyson',
    'Bosch','Siemens','Whirlpool','Electrolux','Tefal','Cuisinart','OXO','Ikea','Belkin','Baseus',
    'TP-Link','Netgear','Razer','Corsair','Garmin','Sennheiser','Haier','Midea','Ninja','Shark'
])[n.rn] || ' ' || d.product_name
FROM (SELECT product_key, ROW_NUMBER() OVER (PARTITION BY product_name ORDER BY product_key) AS rn FROM public.dim_product) n
WHERE d.product_key = n.product_key AND n.rn > 1;

UPDATE public.brand_data SET brand = 'Non Brand'
WHERE brand IS NULL OR LOWER(TRIM(brand)) IN ('', 'n/a', 'na', 'none', 'unknown', 'not specified', 'kitchen')
   OR LOWER(brand) LIKE '%specified%';

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.brand_data WHERE brand IS NOT NULL AND brand != 'Non Brand') THEN
        WITH bd AS (
            SELECT DISTINCT ON (base_name, brand) base_name, brand, price, ebay_matches, n_used
            FROM public.brand_data WHERE brand IS NOT NULL AND brand != 'Non Brand'
            ORDER BY base_name, brand, n_used DESC
        ),
        bd_named AS (SELECT base_name, brand, price, brand || ' ' || base_name AS product_name FROM bd),
        dim_bases AS (
            SELECT dp.product_key, dp.product_name, dp.list_price,
                   (SELECT b.base_name FROM bd_named b WHERE dp.product_name LIKE '% ' || b.base_name ORDER BY length(b.base_name) DESC LIMIT 1) AS base_name
            FROM public.dim_product dp
        )
        UPDATE public.dim_product dp
        SET product_name = bn.product_name, list_price = COALESCE(bn.price, dp.list_price)
        FROM dim_bases db LEFT JOIN bd_named bn ON bn.base_name = db.base_name
        WHERE dp.product_key = db.product_key AND bn.product_name IS NOT NULL AND bn.product_name != db.product_name;
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.ref_cost_benchmark (
    category VARCHAR(50), subcategory VARCHAR(50), ratio_low DECIMAL(5,4), ratio_high DECIMAL(5,4), PRIMARY KEY (category, subcategory)
);
INSERT INTO public.ref_cost_benchmark (category, subcategory, ratio_low, ratio_high) VALUES
    ('Electronics', 'Premium', 0.68, 0.74), ('Electronics', 'Standard', 0.74, 0.80), ('Electronics', 'Budget', 0.80, 0.86),
    ('Home', 'Premium', 0.50, 0.58), ('Home', 'Standard', 0.58, 0.65), ('Home', 'Budget', 0.65, 0.72)
ON CONFLICT (category, subcategory) DO NOTHING;

ALTER TABLE public.dim_product ADD COLUMN IF NOT EXISTS unit_cost_original DECIMAL(12,2);
UPDATE public.dim_product SET unit_cost_original = unit_cost WHERE unit_cost_original IS NULL;
UPDATE public.dim_product dp SET unit_cost = ROUND(dp.list_price * (b.ratio_low + b.ratio_high) / 2.0, 2)
FROM public.ref_cost_benchmark b WHERE b.category = dp.category AND b.subcategory = dp.subcategory AND dp.list_price IS NOT NULL;
ALTER TABLE public.dim_product DROP COLUMN IF EXISTS unit_cost_original;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='dim_product' AND table_schema='public' AND column_name='list_price') THEN
        ALTER TABLE public.dim_product RENAME COLUMN list_price TO retail_price;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='fact_sales' AND table_schema='public' AND column_name='unit_price') THEN
        ALTER TABLE public.fact_sales RENAME COLUMN unit_price TO retail_price;
    END IF;
END $$;

UPDATE public.fact_sales AS fs
SET retail_price = dp.retail_price,
    revenue = ROUND((dp.retail_price * (1 - COALESCE(fs.discount_pct, 0)) * fs.quantity)::numeric, 2)
FROM public.dim_product AS dp WHERE fs.product_key = dp.product_key;
-- === END NOTEBOOK MIGRATIONS ===

-- Consolidated notebook transformations
CREATE OR REPLACE FUNCTION etl.transform_notebook()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    ALTER TABLE public.dim_product ADD COLUMN IF NOT EXISTS category text;

    IF to_regclass('clean.dim_product') IS NOT NULL THEN
        UPDATE public.dim_product AS t SET category = s.product_group FROM clean.dim_product AS s WHERE t.product_key = s.product_key AND (t.category IS NULL OR t.category = '');
    END IF;

    UPDATE public.fact_sales AS fs SET category = dp.category FROM public.dim_product AS dp WHERE fs.product_key = dp.product_key AND (fs.category IS NULL OR fs.category = '');

    UPDATE public.dim_product d
    SET product_name = (ARRAY['Sony','Samsung','LG','Philips','Apple','Xiaomi','Bose','JBL','Anker','Logitech','Dell','ASUS','Lenovo','Huawei','Panasonic','Sharp','Toshiba','Hisense','TCL','Dyson','Bosch','Siemens','Whirlpool','Electrolux','Tefal','Cuisinart','OXO','Ikea','Belkin','Baseus','TP-Link','Netgear','Razer','Corsair','Garmin','Sennheiser','Haier','Midea','Ninja','Shark'])[n.rn] || ' ' || d.product_name
    FROM (SELECT product_key, ROW_NUMBER() OVER (PARTITION BY product_name ORDER BY product_key) AS rn FROM public.dim_product) n
    WHERE d.product_key = n.product_key AND n.rn > 1;

    UPDATE public.brand_data SET brand = 'Non Brand'
    WHERE brand IS NULL OR LOWER(TRIM(brand)) IN ('', 'n/a', 'na', 'none', 'unknown', 'not specified', 'kitchen') OR LOWER(brand) LIKE '%specified%';

    IF EXISTS (SELECT 1 FROM public.brand_data WHERE brand IS NOT NULL AND brand != 'Non Brand') THEN
        WITH bd AS (
            SELECT DISTINCT ON (base_name, brand) base_name, brand, price
            FROM public.brand_data WHERE brand IS NOT NULL AND brand != 'Non Brand'
            ORDER BY base_name, brand, n_used DESC
        ),
        bd_named AS (SELECT base_name, brand, price, brand || ' ' || base_name AS product_name FROM bd),
        dim_bases AS (
            SELECT dp.product_key, dp.product_name, dp.list_price,
                   (SELECT b.base_name FROM bd_named b WHERE dp.product_name LIKE '% ' || b.base_name ORDER BY length(b.base_name) DESC LIMIT 1) AS base_name
            FROM public.dim_product dp
        )
        UPDATE public.dim_product dp
        SET product_name = bn.product_name, list_price = COALESCE(bn.price, dp.list_price)
        FROM dim_bases db LEFT JOIN bd_named bn ON bn.base_name = db.base_name
        WHERE dp.product_key = db.product_key AND bn.product_name IS NOT NULL AND bn.product_name != db.product_name;
    END IF;
END;
$$;
*/
>>>>>>> Stashed changes
