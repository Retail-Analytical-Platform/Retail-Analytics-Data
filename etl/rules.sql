-- rules.sql  (run FIRST, once; safe to re-run)
-- Requires public.dim_product to be loaded (used only to seed the lookup tables).
CREATE SCHEMA IF NOT EXISTS etl;

-- Issue 2 (step 3): product category as independent reference data, keyed by product name.
CREATE TABLE IF NOT EXISTS etl.product_category_map (
    product_name text PRIMARY KEY,
    category     text NOT NULL
);

-- Issue 1: is fact_sales.quantity counted in packs or single units?
CREATE TABLE IF NOT EXISTS etl.quantity_rules (
    rule_id        serial PRIMARY KEY,
    category       text    NOT NULL,
    name_pattern   text    NOT NULL DEFAULT '%',          -- ILIKE pattern on product_name
    quantity_basis text    NOT NULL CHECK (quantity_basis IN ('pack','unit')),
    units_per_pack integer NOT NULL DEFAULT 1 CHECK (units_per_pack >= 1)
);

-- Issue 9 (and 5): cost / price per category + product name
CREATE TABLE IF NOT EXISTS etl.pricing_rules (
    rule_id      serial PRIMARY KEY,
    category     text NOT NULL,
    name_pattern text NOT NULL,
    unit_cost    numeric(10,2) NOT NULL,
    list_price   numeric(10,2) NOT NULL,
    source       text NOT NULL,
    CHECK (list_price >= unit_cost)                       -- Issue 5: no negative margin
);

-- Issues 4, 5, 7: documented decisions
CREATE TABLE IF NOT EXISTS etl.decision_log (
    issue_no   integer PRIMARY KEY,
    decided_on date DEFAULT current_date,
    decision   text NOT NULL,
    rationale  text NOT NULL
);

-- ---- Seeds (only when the table is empty, so your edits are never overwritten) ----

-- Names that have any 'Home' rows in the source are Home; every other name is Electronics.
INSERT INTO etl.product_category_map (product_name, category)
SELECT btrim(product_name),
       CASE WHEN bool_or(category = 'Home') THEN 'Home' ELSE 'Electronics' END
FROM public.dim_product
GROUP BY btrim(product_name)
ON CONFLICT DO NOTHING;

INSERT INTO etl.quantity_rules (category, name_pattern, quantity_basis, units_per_pack)
SELECT * FROM (VALUES
    ('Electronics', '%4-Pack%', 'pack', 4),     -- "Smart Plug 4-Pack": quantity counts packs
    ('Electronics', '%',        'unit', 1),
    ('Home',        '%',        'unit', 1)      -- "...Set" items are sold as one unit
) v(category, name_pattern, quantity_basis, units_per_pack)
WHERE NOT EXISTS (SELECT 1 FROM etl.quantity_rules);

-- PLACEHOLDER pricing: median source unit_cost per product name, list price = cost x 1.60.
-- Replace with real business reference values when available (UPDATE etl.pricing_rules ...).
INSERT INTO etl.pricing_rules (category, name_pattern, unit_cost, list_price, source)
SELECT m.category, m.product_name, x.c, round(x.c * 1.60, 2),
       'PLACEHOLDER: median source unit_cost x 1.60'
FROM (SELECT btrim(product_name) AS n,
             round(percentile_cont(0.5) WITHIN GROUP (ORDER BY unit_cost)::numeric, 2) AS c
      FROM public.dim_product GROUP BY btrim(product_name)) x
JOIN etl.product_category_map m ON m.product_name = x.n
WHERE NOT EXISTS (SELECT 1 FROM etl.pricing_rules);

INSERT INTO etl.decision_log (issue_no, decision, rationale) VALUES
 (4, 'accept', 'discount_pct is a constant 0.35 on every row; no variation to clean. Documented as a flat-rate assumption.'),
 (5, 'fix',    '78% of source products had unit_cost > list_price (systemic generator defect, not clearance). Prices now come from etl.pricing_rules.'),
 (7, 'accept', 'Official revenue = round(quantity * unit_price * (1 - discount_pct), 2). Source revenue column is kept for audit only.')
ON CONFLICT (issue_no) DO NOTHING;
