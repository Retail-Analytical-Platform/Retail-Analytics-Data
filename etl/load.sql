-- load.sql  (replaces the old file)
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

    -- Issue 8 (Option A): fact keeps the original sale category; product categories exposed beside it
    EXECUTE $v$
        CREATE VIEW clean.v_fact_sales AS
        SELECT f.*, p.category AS product_category, p.product_group, f.revenue_expected AS net_revenue
        FROM clean.fact_sales f JOIN clean.dim_product p USING (product_key)
    $v$;

    -- Issue 7: documented definitions
    COMMENT ON COLUMN clean.fact_sales.revenue IS
        'Source revenue, kept for audit only. Not reliable: see revenue_mismatch.';
    COMMENT ON COLUMN clean.fact_sales.revenue_expected IS
        'Official net revenue = round(quantity * unit_price * (1 - discount_pct), 2)';
    COMMENT ON COLUMN clean.fact_sales.units_sold IS
        'Quantity in single units: quantity * units_per_pack when quantity_basis = pack';
END;
$$;

<<<<<<< Updated upstream
-- Notebook call: SELECT etl.load();
=======
-- Notebook-derived load transformations applied after the clean dimensions
-- have been updated by etl.apply_notebook_transform().
CREATE OR REPLACE FUNCTION etl.apply_notebook_load()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    DROP VIEW IF EXISTS clean.v_fact_sales;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'clean' AND table_name = 'dim_product'
          AND column_name = 'list_price'
    ) THEN
        ALTER TABLE clean.dim_product RENAME COLUMN list_price TO retail_price;
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'clean' AND table_name = 'fact_sales'
          AND column_name = 'unit_price'
    ) THEN
        ALTER TABLE clean.fact_sales RENAME COLUMN unit_price TO retail_price;
    END IF;

    UPDATE clean.fact_sales f
    SET retail_price = p.retail_price,
        revenue = round((p.retail_price * (1 - coalesce(f.discount_pct, 0)) * f.quantity)::numeric, 2),
        revenue_expected = round((p.retail_price * (1 - coalesce(f.discount_pct, 0)) * f.quantity)::numeric, 2)
    FROM clean.dim_product p
    WHERE p.product_key = f.product_key;

    CREATE VIEW clean.v_fact_sales AS
    SELECT f.*, p.category AS product_category, p.product_group,
           f.revenue_expected AS net_revenue
    FROM clean.fact_sales f
    JOIN clean.dim_product p USING (product_key);
END;
$$;

/* Notebook migrations are intentionally excluded from the Docker ETL path.
   They mutate the public source schema (including renaming list_price and
   unit_price) and are not part of the staged transform/load contract.
CREATE TABLE IF NOT EXISTS public.brand_data (
    base_name text, brand text, ebay_matches integer, n_used integer, price numeric(12,2), low numeric(12,2), high numeric(12,2)
);
ALTER TABLE public.dim_product ADD COLUMN IF NOT EXISTS category text;

DO $$
BEGIN
    IF to_regclass('clean.dim_product') IS NOT NULL THEN
        UPDATE public.dim_product AS t SET category = s.product_group FROM clean.dim_product AS s WHERE t.product_key = s.product_key AND t.category IS NULL;
    END IF;
END $$;

UPDATE public.fact_sales AS fs SET category = dp.category FROM public.dim_product AS dp WHERE fs.product_key = dp.product_key AND fs.category IS NULL;

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

-- Consolidated notebook load transformations
CREATE OR REPLACE FUNCTION etl.load_notebook()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM etl.transform_notebook();

    ALTER TABLE public.dim_product ADD COLUMN IF NOT EXISTS unit_cost_original DECIMAL(12,2);
    UPDATE public.dim_product SET unit_cost_original = unit_cost WHERE unit_cost_original IS NULL;

    UPDATE public.dim_product dp SET unit_cost = ROUND(dp.list_price * ((b.ratio_low + b.ratio_high)/2.0), 2)
    FROM public.ref_cost_benchmark b
    WHERE b.category = dp.category AND b.subcategory = dp.subcategory AND dp.list_price IS NOT NULL;

    ALTER TABLE public.dim_product DROP COLUMN IF EXISTS unit_cost_original;

    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='dim_product' AND table_schema='public' AND column_name='list_price') THEN
        ALTER TABLE public.dim_product RENAME COLUMN list_price TO retail_price;
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='fact_sales' AND table_schema='public' AND column_name='unit_price') THEN
        ALTER TABLE public.fact_sales RENAME COLUMN unit_price TO retail_price;
    END IF;

    UPDATE public.fact_sales AS fs
    SET retail_price = dp.retail_price,
        revenue = ROUND((dp.retail_price * (1 - COALESCE(fs.discount_pct,0)) * fs.quantity)::numeric, 2)
    FROM public.dim_product AS dp
    WHERE fs.product_key = dp.product_key;
END;
$$;
*/
>>>>>>> Stashed changes
