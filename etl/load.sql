CREATE SCHEMA IF NOT EXISTS etl;

CREATE OR REPLACE FUNCTION etl.load()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['dim_date', 'dim_product', 'dim_customer', 'dim_store', 'fact_sales']
    LOOP
        IF to_regclass('transformed.' || t) IS NULL THEN
            RAISE EXCEPTION 'transformed.% does not exist; run etl.transform() first', t;
        END IF;
    END LOOP;

    CREATE SCHEMA IF NOT EXISTS clean;
    DROP VIEW  IF EXISTS clean.v_fact_sales;
    DROP TABLE IF EXISTS clean.fact_sales;
    DROP TABLE IF EXISTS clean.dim_store;
    DROP TABLE IF EXISTS clean.dim_customer;
    DROP TABLE IF EXISTS clean.dim_product;
    DROP TABLE IF EXISTS clean.dim_date;

    ALTER TABLE transformed.dim_date SET SCHEMA clean;
    ALTER TABLE clean.dim_date ADD PRIMARY KEY (date_key);
    ALTER TABLE clean.dim_date ADD CONSTRAINT chk_month_name CHECK (          -- Issue 3
        array_position(ARRAY['January','February','March','April','May','June',
        'July','August','September','October','November','December'], month_name)
        = extract(month FROM full_date)::int);

    ALTER TABLE transformed.dim_product SET SCHEMA clean;
    ALTER TABLE clean.dim_product ALTER COLUMN product_group SET NOT NULL;
    ALTER TABLE clean.dim_product ADD PRIMARY KEY (product_key);
    ALTER TABLE clean.dim_product ADD CONSTRAINT chk_margin CHECK (list_price >= unit_cost);  -- Issue 5

    ALTER TABLE transformed.dim_customer SET SCHEMA clean;
    ALTER TABLE clean.dim_customer ADD PRIMARY KEY (customer_key);
    ALTER TABLE transformed.dim_store SET SCHEMA clean;
    ALTER TABLE clean.dim_store ADD PRIMARY KEY (store_key);

    ALTER TABLE transformed.fact_sales SET SCHEMA clean;
    ALTER TABLE clean.fact_sales ADD PRIMARY KEY (sale_id);
    ALTER TABLE clean.fact_sales ADD CONSTRAINT chk_discount                   -- Issue 4
        CHECK (discount_pct >= 0 AND discount_pct < 1);

    CREATE INDEX idx_fact_sales_date_key     ON clean.fact_sales (date_key);
    CREATE INDEX idx_fact_sales_product_key  ON clean.fact_sales (product_key);
    CREATE INDEX idx_fact_sales_customer_key ON clean.fact_sales (customer_key);
    CREATE INDEX idx_fact_sales_store_key    ON clean.fact_sales (store_key);

    CREATE VIEW clean.v_fact_sales AS
    SELECT f.*, p.category AS product_category, p.product_group, f.revenue_expected AS net_revenue
    FROM clean.fact_sales f JOIN clean.dim_product p USING (product_key);

    COMMENT ON COLUMN clean.fact_sales.revenue IS
        'Source revenue, kept for audit only. Not reliable: see revenue_mismatch.';
    COMMENT ON COLUMN clean.fact_sales.revenue_expected IS
        'Official net revenue = round(quantity * unit_price * (1 - discount_pct), 2)';
    COMMENT ON COLUMN clean.fact_sales.units_sold IS
        'Quantity in single units: quantity * units_per_pack when quantity_basis = pack';
END;
$$;