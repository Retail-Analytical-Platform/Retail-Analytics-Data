CREATE SCHEMA IF NOT EXISTS etl;

-- Part 1 -----------------------------------------------------------------
CREATE OR REPLACE FUNCTION etl.load()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['dim_date', 'dim_product', 'dim_customer', 'dim_store',
                             'fact_sales', 'customer_dedup_map', 'customer_review',
                             'customer_duplicate_pairs']
    LOOP
        IF to_regclass('transformed.' || t) IS NULL THEN
            RAISE EXCEPTION 'transformed.% does not exist; run etl.transform() first', t;
        END IF;
    END LOOP;

    CREATE SCHEMA IF NOT EXISTS clean;
    DROP VIEW  IF EXISTS clean.v_fact_sales;
    DROP TABLE IF EXISTS clean.category_audit;
    DROP TABLE IF EXISTS clean.customer_duplicate_pairs;
    DROP TABLE IF EXISTS clean.customer_review;
    DROP TABLE IF EXISTS clean.customer_dedup_map;
    DROP TABLE IF EXISTS clean.fact_sales;
    DROP TABLE IF EXISTS clean.dim_store;
    DROP TABLE IF EXISTS clean.dim_customer;
    DROP TABLE IF EXISTS clean.dim_product;
    DROP TABLE IF EXISTS clean.dim_date;

    CREATE TABLE clean.dim_date AS TABLE transformed.dim_date;
    ALTER TABLE clean.dim_date ADD PRIMARY KEY (date_key);
    ALTER TABLE clean.dim_date ADD CONSTRAINT chk_month_name CHECK (          -- Issue 3
        array_position(ARRAY['January','February','March','April','May','June',
        'July','August','September','October','November','December'], month_name)
        = extract(month FROM full_date)::int);

    CREATE TABLE clean.dim_product AS TABLE transformed.dim_product;
    ALTER TABLE clean.dim_product ALTER COLUMN product_group SET NOT NULL;
    ALTER TABLE clean.dim_product ADD PRIMARY KEY (product_key);
    ALTER TABLE clean.dim_product ADD CONSTRAINT chk_margin CHECK (list_price >= unit_cost);  -- Issue 5

    CREATE TABLE clean.dim_customer AS TABLE transformed.dim_customer;
    ALTER TABLE clean.dim_customer ADD PRIMARY KEY (customer_key);
    CREATE TABLE clean.dim_store AS TABLE transformed.dim_store;
    ALTER TABLE clean.dim_store ADD PRIMARY KEY (store_key);

    CREATE TABLE clean.fact_sales AS TABLE transformed.fact_sales;
    ALTER TABLE clean.fact_sales ADD PRIMARY KEY (sale_id);
    ALTER TABLE clean.fact_sales ADD CONSTRAINT chk_discount                   -- Issue 4
        CHECK (discount_pct >= 0 AND discount_pct < 1);

    CREATE TABLE clean.customer_dedup_map AS TABLE transformed.customer_dedup_map;
    CREATE TABLE clean.customer_review AS TABLE transformed.customer_review;
    CREATE TABLE clean.customer_duplicate_pairs AS TABLE transformed.customer_duplicate_pairs;

    ALTER TABLE clean.fact_sales ADD FOREIGN KEY (date_key) REFERENCES clean.dim_date(date_key);
    ALTER TABLE clean.fact_sales ADD FOREIGN KEY (product_key) REFERENCES clean.dim_product(product_key);
    ALTER TABLE clean.fact_sales ADD FOREIGN KEY (customer_key) REFERENCES clean.dim_customer(customer_key);
    ALTER TABLE clean.fact_sales ADD FOREIGN KEY (store_key) REFERENCES clean.dim_store(store_key);

    EXECUTE $v$
        CREATE VIEW clean.v_fact_sales AS
        SELECT f.*, p.category AS product_category, p.product_group, f.revenue_expected AS net_revenue
        FROM clean.fact_sales f JOIN clean.dim_product p USING (product_key)
    $v$;

    COMMENT ON COLUMN clean.fact_sales.revenue IS
        'Source revenue, kept for audit only. Not reliable: see revenue_mismatch.';
    COMMENT ON COLUMN clean.fact_sales.revenue_expected IS
        'Official net revenue = round(quantity * unit_price * (1 - discount_pct), 2)';
    COMMENT ON COLUMN clean.fact_sales.units_sold IS
        'Quantity in single units: quantity * units_per_pack when quantity_basis = pack';
END;
$$;

-- Part 2 -----------------------------------------------------------------
-- Rename first, so every statement below uses retail_price and still works
-- when an earlier run (or transform.sql) already renamed the columns.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public' AND table_name = 'dim_product'
                 AND column_name = 'list_price') THEN
        ALTER TABLE public.dim_product RENAME COLUMN list_price TO retail_price;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public' AND table_name = 'fact_sales'
                 AND column_name = 'unit_price') THEN
        ALTER TABLE public.fact_sales RENAME COLUMN unit_price TO retail_price;
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.brand_data (
    base_name text, brand text, ebay_matches integer, n_used integer,
    price numeric(12,2), low numeric(12,2), high numeric(12,2)
);
ALTER TABLE public.dim_product ADD COLUMN IF NOT EXISTS category text;
ALTER TABLE public.fact_sales  ADD COLUMN IF NOT EXISTS category text;

DO $$
BEGIN
    IF to_regclass('clean.dim_product') IS NOT NULL THEN
        UPDATE public.dim_product AS t
        SET category = s.product_group
        FROM clean.dim_product AS s
        WHERE t.product_key = s.product_key AND t.category IS NULL;
    END IF;
END $$;

UPDATE public.fact_sales AS fs
SET category = dp.category
FROM public.dim_product AS dp
WHERE fs.product_key = dp.product_key AND fs.category IS NULL;

-- Give repeated product names a brand prefix. The upper bound stops a name that
-- repeats more often than there are brands from becoming NULL.
WITH b AS (
    SELECT ARRAY[
        'Sony','Samsung','LG','Philips','Apple','Xiaomi','Bose','JBL','Anker','Logitech',
        'Dell','ASUS','Lenovo','Huawei','Panasonic','Sharp','Toshiba','Hisense','TCL','Dyson',
        'Bosch','Siemens','Whirlpool','Electrolux','Tefal','Cuisinart','OXO','Ikea','Belkin','Baseus',
        'TP-Link','Netgear','Razer','Corsair','Garmin','Sennheiser','Haier','Midea','Ninja','Shark'
    ] AS names
), n AS (
    SELECT product_key,
           ROW_NUMBER() OVER (PARTITION BY product_name ORDER BY product_key) AS rn
    FROM public.dim_product
)
UPDATE public.dim_product d
SET product_name = b.names[n.rn] || ' ' || d.product_name
FROM n, b
WHERE d.product_key = n.product_key
  AND n.rn BETWEEN 2 AND cardinality(b.names);

UPDATE public.brand_data SET brand = 'Non Brand'
WHERE brand IS NULL OR LOWER(TRIM(brand)) IN ('', 'n/a', 'na', 'none', 'unknown', 'not specified', 'kitchen')
   OR LOWER(brand) LIKE '%specified%';

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.brand_data WHERE brand IS NOT NULL AND brand != 'Non Brand') THEN
        WITH bd AS (
            SELECT DISTINCT ON (base_name, brand) base_name, brand, price
            FROM public.brand_data
            WHERE brand IS NOT NULL AND brand != 'Non Brand'
            ORDER BY base_name, brand, n_used DESC
        ),
        bd_named AS (
            SELECT base_name, brand, price, brand || ' ' || base_name AS product_name FROM bd
        ),
        dim_bases AS (
            SELECT dp.product_key, dp.product_name, dp.retail_price,
                   (SELECT b.base_name FROM bd_named b
                    WHERE dp.product_name LIKE '% ' || b.base_name
                    ORDER BY length(b.base_name) DESC LIMIT 1) AS base_name
            FROM public.dim_product dp
        )
        UPDATE public.dim_product dp
        SET product_name = bn.product_name,
            retail_price = COALESCE(bn.price, dp.retail_price)
        FROM dim_bases db LEFT JOIN bd_named bn ON bn.base_name = db.base_name
        WHERE dp.product_key = db.product_key
          AND bn.product_name IS NOT NULL
          AND bn.product_name != db.product_name;
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.ref_cost_benchmark (
    category VARCHAR(50), subcategory VARCHAR(50),
    ratio_low DECIMAL(5,4), ratio_high DECIMAL(5,4),
    PRIMARY KEY (category, subcategory)
);
INSERT INTO public.ref_cost_benchmark (category, subcategory, ratio_low, ratio_high) VALUES
    ('Electronics', 'Premium', 0.68, 0.74), ('Electronics', 'Standard', 0.74, 0.80), ('Electronics', 'Budget', 0.80, 0.86),
    ('Home', 'Premium', 0.50, 0.58), ('Home', 'Standard', 0.58, 0.65), ('Home', 'Budget', 0.65, 0.72)
ON CONFLICT (category, subcategory) DO NOTHING;

-- Pricing repair: unit_cost = retail_price * mid-point cost ratio of its category.
UPDATE public.dim_product dp
SET unit_cost = ROUND(dp.retail_price * (b.ratio_low + b.ratio_high) / 2.0, 2)
FROM public.ref_cost_benchmark b
WHERE b.category = dp.category AND b.subcategory = dp.subcategory
  AND dp.retail_price IS NOT NULL;

UPDATE public.fact_sales AS fs
SET retail_price = dp.retail_price,
    revenue = ROUND((dp.retail_price * (1 - COALESCE(fs.discount_pct, 0)) * fs.quantity)::numeric, 2)
FROM public.dim_product AS dp
WHERE fs.product_key = dp.product_key;

-- Part 3 -----------------------------------------------------------------
-- Same pricing repair as above, callable on demand after etl.transform_notebook().
CREATE OR REPLACE FUNCTION etl.load_notebook()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM etl.transform_notebook();

    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public' AND table_name = 'dim_product'
                 AND column_name = 'list_price') THEN
        ALTER TABLE public.dim_product RENAME COLUMN list_price TO retail_price;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public' AND table_name = 'fact_sales'
                 AND column_name = 'unit_price') THEN
        ALTER TABLE public.fact_sales RENAME COLUMN unit_price TO retail_price;
    END IF;

    UPDATE public.dim_product dp
    SET unit_cost = ROUND(dp.retail_price * (b.ratio_low + b.ratio_high) / 2.0, 2)
    FROM public.ref_cost_benchmark b
    WHERE b.category = dp.category AND b.subcategory = dp.subcategory
      AND dp.retail_price IS NOT NULL;

    UPDATE public.fact_sales AS fs
    SET retail_price = dp.retail_price,
        revenue = ROUND((dp.retail_price * (1 - COALESCE(fs.discount_pct, 0)) * fs.quantity)::numeric, 2)
    FROM public.dim_product AS dp
    WHERE fs.product_key = dp.product_key;
END;
$$;