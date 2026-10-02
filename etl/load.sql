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

-- Notebook call: SELECT etl.load();