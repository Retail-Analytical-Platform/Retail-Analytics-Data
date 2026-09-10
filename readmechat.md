# Business Analysis Project — Retail Sales Star Schema

Analysis of the 5-file dataset at `~/Projects/Business-Analysis/data/`.
Diagram: https://claude.ai/code/artifact/2474ab0c-9ee3-424d-a20e-100099ec6c7e

## 1. Files & how they relate

A star schema: `fact_sales` is the fact table; the other four are dimensions joined to it
1‑to‑many via a surrogate key.

```
dim_customer(customer_key) ─┐
dim_date(date_key)         ─┼─< fact_sales >─┬─ dim_product(product_key)
dim_store(store_key)       ─┘                │
                                              └─ fact_sales.category (denormalized copy
                                                 of dim_product.category — unreliable,
                                                 see DQ-1 below)
```

| File | Rows | Primary key | Notes |
|---|---|---|---|
| `dim_customer.csv` | 2,000 | `customer_key` | customer_name, email, city, country, segment |
| `dim_date.csv` | 730 | `date_key` | full_date, day_of_week, month_name, quarter, is_weekend |
| `dim_product.csv` | 400 | `product_key` | product_name, category, subcategory, unit_cost, list_price |
| `dim_store.csv` | 40 | `store_key` | store_name, region, store_type |
| `fact_sales.csv` | 60,000 | `sale_id` | date_key, product_key, customer_key, store_key FKs + quantity, unit_price, discount_pct, revenue, category |

All four foreign keys in `fact_sales` are 100% valid — **zero orphaned rows** in either
direction. No NULLs anywhere, no duplicate primary keys, no duplicate full rows.

## 2. Data quality findings

| ID | Issue | Scale |
|---|---|---|
| DQ-1 | `fact_sales.category` disagrees with `dim_product.category` (joined on `product_key`) | 43,501 / 60,000 rows (72.5%) |
| DQ-2 | `discount_pct` is constant — every row equals `0.35`, zero variance | 60,000 / 60,000 rows |
| DQ-3 | `revenue` ≠ `quantity × unit_price × (1 − discount_pct)` | 59,948 / 60,000 rows (99.9%) |
| DQ-4 | `dim_date.quarter` doesn't match the quarter implied by `month_name` | 558 / 730 rows (76.4%) |
| DQ-5 | `dim_date.is_weekend` doesn't match `day_of_week` (Sat/Sun) | 351 / 730 rows (48.1%) |
| DQ-6 | Duplicate `email` shared across distinct `customer_key` values in `dim_customer` | 15 emails |

**Takeaway:** treat `dim_product.category` as the source of truth for category (not the
fact table's own column), treat `discount_pct` as a dead/placeholder field, don't use the
naive revenue formula as a validation check, and rebuild `quarter`/`is_weekend` in
`dim_date` from `full_date`/`day_of_week` rather than trusting the stored values.

## 3. Schema (DDL) — PostgreSQL

```sql
CREATE TABLE dim_customer (
    customer_key BIGINT PRIMARY KEY,
    customer_name TEXT,
    email TEXT,
    city TEXT,
    country TEXT,
    segment TEXT
);

CREATE TABLE dim_date (
    date_key BIGINT PRIMARY KEY,
    full_date TIMESTAMP,
    day_of_week TEXT,
    month_name TEXT,
    quarter TEXT,
    is_weekend BOOLEAN
);

CREATE TABLE dim_product (
    product_key BIGINT PRIMARY KEY,
    product_name TEXT,
    category TEXT,
    subcategory TEXT,
    unit_cost NUMERIC(10,2),
    list_price NUMERIC(10,2)
);

CREATE TABLE dim_store (
    store_key BIGINT PRIMARY KEY,
    store_name TEXT,
    region TEXT,
    store_type TEXT
);

CREATE TABLE fact_sales (
    sale_id BIGINT PRIMARY KEY,
    date_key BIGINT REFERENCES dim_date(date_key),
    product_key BIGINT REFERENCES dim_product(product_key),
    customer_key BIGINT REFERENCES dim_customer(customer_key),
    store_key BIGINT REFERENCES dim_store(store_key),
    sold_at TIMESTAMP,
    quantity INTEGER,
    unit_price NUMERIC(10,2),
    discount_pct NUMERIC(4,2),
    revenue NUMERIC(10,2),
    category TEXT   -- denormalized & unreliable, see DQ-1
);
```

## 4. Loading the CSVs (psql)

```sql
\copy dim_customer FROM '/home/joseph/Projects/Business-Analysis/data/dim_customer.csv' WITH (FORMAT csv, HEADER true);
\copy dim_date     FROM '/home/joseph/Projects/Business-Analysis/data/dim_date.csv'     WITH (FORMAT csv, HEADER true);
\copy dim_product  FROM '/home/joseph/Projects/Business-Analysis/data/dim_product.csv'  WITH (FORMAT csv, HEADER true);
\copy dim_store    FROM '/home/joseph/Projects/Business-Analysis/data/dim_store.csv'    WITH (FORMAT csv, HEADER true);
\copy fact_sales   FROM '/home/joseph/Projects/Business-Analysis/data/fact_sales.csv'   WITH (FORMAT csv, HEADER true);
```

## 5. Cleaning SQL

```sql
-- 5.1 Confirm referential integrity (each should return 0 rows)
SELECT f.sale_id FROM fact_sales f LEFT JOIN dim_customer c ON f.customer_key = c.customer_key WHERE c.customer_key IS NULL;
SELECT f.sale_id FROM fact_sales f LEFT JOIN dim_date d ON f.date_key = d.date_key WHERE d.date_key IS NULL;
SELECT f.sale_id FROM fact_sales f LEFT JOIN dim_product p ON f.product_key = p.product_key WHERE p.product_key IS NULL;
SELECT f.sale_id FROM fact_sales f LEFT JOIN dim_store s ON f.store_key = s.store_key WHERE s.store_key IS NULL;

-- 5.2 Resolve DQ-1: always source category from dim_product, not fact_sales.category
CREATE OR REPLACE VIEW fact_sales_clean AS
SELECT
    f.sale_id, f.date_key, f.product_key, f.customer_key, f.store_key,
    f.sold_at, f.quantity, f.unit_price, f.discount_pct, f.revenue,
    p.category, p.subcategory
FROM fact_sales f
JOIN dim_product p ON f.product_key = p.product_key;

-- Or fix the base table directly:
UPDATE fact_sales f
SET category = p.category
FROM dim_product p
WHERE f.product_key = p.product_key
  AND f.category IS DISTINCT FROM p.category;

-- 5.3 Fix DQ-4: quarter should be derived from full_date, not trusted as-is
UPDATE dim_date
SET quarter = 'Q' || CEIL(EXTRACT(MONTH FROM full_date) / 3.0)::INT
WHERE quarter <> 'Q' || CEIL(EXTRACT(MONTH FROM full_date) / 3.0)::INT;

-- 5.4 Fix DQ-5: is_weekend should be derived from day_of_week
UPDATE dim_date
SET is_weekend = (day_of_week IN ('Saturday', 'Sunday'))
WHERE is_weekend <> (day_of_week IN ('Saturday', 'Sunday'));

-- 5.5 Surface DQ-3 rather than overwrite revenue (source of truth is unknown)
SELECT sale_id, quantity, unit_price, discount_pct, revenue,
       ROUND(quantity * unit_price * (1 - discount_pct), 2) AS expected_revenue,
       ROUND(revenue - quantity * unit_price * (1 - discount_pct), 2) AS diff
FROM fact_sales
WHERE ABS(revenue - quantity * unit_price * (1 - discount_pct)) > 0.05
ORDER BY ABS(diff) DESC;

-- 5.6 Confirm DQ-2 (discount_pct has zero variance)
SELECT COUNT(DISTINCT discount_pct) AS distinct_discounts, MIN(discount_pct), MAX(discount_pct)
FROM fact_sales;

-- 5.7 Surface DQ-6 for a data steward rather than auto-merge
SELECT email, COUNT(*) AS n, STRING_AGG(customer_key::TEXT, ', ') AS customer_keys
FROM dim_customer
GROUP BY email
HAVING COUNT(*) > 1
ORDER BY n DESC;

-- 5.8 Standardize text fields defensively
UPDATE dim_customer SET
    customer_name = TRIM(customer_name),
    email = LOWER(TRIM(email)),
    city = TRIM(city),
    country = UPPER(TRIM(country));

-- 5.9 Bounds sanity check (should return 0 rows)
SELECT * FROM fact_sales
WHERE quantity <= 0 OR unit_price <= 0 OR revenue <= 0 OR discount_pct NOT BETWEEN 0 AND 1;
```

## 6. Descriptive statistics — mean, median, mode, min, max, spread

```sql
-- 6.1 Full descriptive stats on the key numeric measures
SELECT
    'quantity' AS metric,
    MIN(quantity)::NUMERIC AS min_val,
    MAX(quantity)::NUMERIC AS max_val,
    ROUND(AVG(quantity), 4) AS mean,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY quantity) AS median,
    MODE() WITHIN GROUP (ORDER BY quantity) AS mode,
    ROUND(STDDEV(quantity), 4) AS stddev,
    ROUND(VARIANCE(quantity), 4) AS variance
FROM fact_sales
UNION ALL
SELECT 'unit_price',
    MIN(unit_price), MAX(unit_price), ROUND(AVG(unit_price), 4),
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY unit_price),
    MODE() WITHIN GROUP (ORDER BY unit_price),
    ROUND(STDDEV(unit_price), 4), ROUND(VARIANCE(unit_price), 4)
FROM fact_sales
UNION ALL
SELECT 'revenue',
    MIN(revenue), MAX(revenue), ROUND(AVG(revenue), 4),
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY revenue),
    MODE() WITHIN GROUP (ORDER BY revenue),
    ROUND(STDDEV(revenue), 4), ROUND(VARIANCE(revenue), 4)
FROM fact_sales
UNION ALL
SELECT 'discount_pct',
    MIN(discount_pct), MAX(discount_pct), ROUND(AVG(discount_pct), 4),
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY discount_pct),
    MODE() WITHIN GROUP (ORDER BY discount_pct),
    ROUND(STDDEV(discount_pct), 4), ROUND(VARIANCE(discount_pct), 4)
FROM fact_sales;

-- 6.2 Mode via window function (portable to any SQL dialect, not just Postgres)
SELECT category, cnt FROM (
    SELECT p.category, COUNT(*) AS cnt,
           RANK() OVER (ORDER BY COUNT(*) DESC) AS rnk
    FROM fact_sales f
    JOIN dim_product p ON f.product_key = p.product_key
    GROUP BY p.category
) t WHERE rnk = 1;

-- 6.3 Quartiles / IQR for outlier detection on revenue
SELECT
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY revenue) AS q1,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY revenue) AS median,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY revenue) AS q3
FROM fact_sales;
```

## 7. Cross-table patterns (joining all 5 tables)

```sql
-- 7.1 Revenue by region, category, and quarter — full star join
SELECT
    s.region, p.category, d.quarter,
    COUNT(*) AS num_sales,
    SUM(f.revenue) AS total_revenue,
    ROUND(AVG(f.revenue), 2) AS avg_revenue,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY f.revenue) AS median_revenue
FROM fact_sales f
JOIN dim_store   s ON f.store_key = s.store_key
JOIN dim_product p ON f.product_key = p.product_key
JOIN dim_date    d ON f.date_key = d.date_key
GROUP BY s.region, p.category, d.quarter
ORDER BY total_revenue DESC;

-- 7.2 Top 10 customers by lifetime revenue
SELECT c.customer_key, c.customer_name, c.segment, c.country,
       COUNT(*) AS orders, SUM(f.revenue) AS lifetime_revenue,
       ROUND(AVG(f.revenue), 2) AS avg_order_value
FROM fact_sales f
JOIN dim_customer c ON f.customer_key = c.customer_key
GROUP BY c.customer_key, c.customer_name, c.segment, c.country
ORDER BY lifetime_revenue DESC
LIMIT 10;

-- 7.3 Best-selling products with margin (from dim_product cost/price)
SELECT p.product_key, p.product_name, p.category,
       SUM(f.quantity) AS units_sold,
       SUM(f.revenue) AS total_revenue,
       ROUND(AVG(f.revenue / NULLIF(f.quantity,0)), 2) AS avg_revenue_per_unit,
       p.unit_cost, p.list_price,
       ROUND(p.list_price - p.unit_cost, 2) AS unit_margin
FROM fact_sales f
JOIN dim_product p ON f.product_key = p.product_key
GROUP BY p.product_key, p.product_name, p.category, p.unit_cost, p.list_price
ORDER BY total_revenue DESC
LIMIT 20;

-- 7.4 Weekday vs weekend sales pattern
SELECT d.is_weekend, COUNT(*) AS num_sales, SUM(f.revenue) AS total_revenue,
       ROUND(AVG(f.revenue), 2) AS avg_revenue
FROM fact_sales f
JOIN dim_date d ON f.date_key = d.date_key
GROUP BY d.is_weekend;

-- 7.5 Monthly trend (uses corrected quarter/month from cleaned dim_date)
SELECT d.month_name, d.quarter,
       COUNT(*) AS num_sales, SUM(f.revenue) AS total_revenue
FROM fact_sales f
JOIN dim_date d ON f.date_key = d.date_key
GROUP BY d.month_name, d.quarter
ORDER BY MIN(d.full_date);

-- 7.6 Store performance ranking within region
SELECT s.region, s.store_name, s.store_type,
       SUM(f.revenue) AS total_revenue,
       RANK() OVER (PARTITION BY s.region ORDER BY SUM(f.revenue) DESC) AS rank_in_region
FROM fact_sales f
JOIN dim_store s ON f.store_key = s.store_key
GROUP BY s.region, s.store_name, s.store_type;

-- 7.7 Customer segment behavior (spend habits by segment)
SELECT c.segment,
       COUNT(DISTINCT c.customer_key) AS num_customers,
       COUNT(*) AS num_orders,
       ROUND(AVG(f.revenue), 2) AS avg_order_value,
       ROUND(SUM(f.revenue) / COUNT(DISTINCT c.customer_key), 2) AS revenue_per_customer
FROM fact_sales f
JOIN dim_customer c ON f.customer_key = c.customer_key
GROUP BY c.segment
ORDER BY revenue_per_customer DESC;

-- 7.8 Correlation: does higher unit_price correlate with higher quantity bought?
SELECT CORR(unit_price, quantity) AS price_qty_correlation FROM fact_sales;
```

## Notes

- Dialect: PostgreSQL. `PERCENTILE_CONT` / `MODE() WITHIN GROUP` are Postgres/Oracle/SQL
  Server syntax; MySQL 8 has no native median function — emulate with `PERCENT_RANK()`
  over a window instead.
- Source data: `/home/joseph/Projects/Business-Analysis/data/*.csv` (5 files, 63,171 rows
  total across all tables).
- Visual diagram of the schema + flags: https://claude.ai/code/artifact/2474ab0c-9ee3-424d-a20e-100099ec6c7e
