# SQL Analysis Walkthrough — Retail Sales Star Schema

This document explains the **correlations between data** (how the tables
connect to each other) and **every SQL statement** run in `src/main.ipynb`,
in sequence — each query is explained in relation to the query before and
after it, closing with a conclusion.

> The connection cell uses a plaintext database password
> (`postgresql://postgres:@localhost:5432/postgres`) and this file
> is already in the git history. The password should be moved to an
> environment variable and rotated.

---

## 1. Data Correlation — How All the Tables Relate

This dataset is a **star schema**: one fact table (`fact_sales`, 60,000 rows)
in the center, surrounded by four dimension tables, each connected through a
foreign key (surrogate key):

```
dim_customer(customer_key) ─┐
dim_date(date_key)         ─┼─< fact_sales >─── dim_product(product_key)
dim_store(store_key)       ─┘
```

| Table | Rows | Primary Key | Role |
|---|---|---|---|
| `dim_customer` | 2,000 | `customer_key` | who bought |
| `dim_date` | 730 | `date_key` | when the transaction happened |
| `dim_product` | ~400 | `product_key` | what was bought |
| `dim_store` | 40 | `store_key` | which store/region |
| `fact_sales` | 60,000 | `sale_id` | the transaction itself (qty, price, discount, revenue) |

There are two levels of correlation between the data here:

1. **Structural (relational) correlation** — every `fact_sales` row
   "correlates" to exactly one row in each dimension via FK. This is what
   makes joins possible and aggregation (total revenue per region, per
   category, per month, etc.) valid.
2. **Statistical (numeric) correlation** — the relationship between two
   numeric variables, e.g. whether a higher `unit_price` tends to be bought
   in a larger or smaller `quantity`. This is measured via the `CORR()`
   function at the end of the notebook (see §2.24) — the result is close to
   zero, meaning **there's no relationship** between unit price and the
   quantity purchased.

Both kinds of correlation underpin every query in the notebook: the early
queries validate structural correlation (FK integrity), the middle queries
clean the data, and the final queries analyze statistical/business
correlation (revenue by segment, by time, by store, etc.).

---

## 2. SQL Walkthrough — In Sequence

### 2.1 Connection
```sql
%load_ext sql
%sql postgresql://postgres:***@localhost:5432/postgres
```
Opens a connection to the Postgres database. This is the foundation — every
`%%sql` query after this runs through this connection.

### 2.2 Listing all existing tables
```sql
SELECT * FROM information_schema.tables WHERE table_schema = 'public';
```
After connecting (2.1), the first step is to **confirm the schema is
loaded** by reading the `information_schema.tables` system catalog. Result: 5
base tables + 1 view (`fact_sales_clean`, created later in 2.7) — meaning
this notebook had already been run before, since that view already exists.

### 2.3 Exploring `dim_date`
```sql
SELECT * FROM dim_date;                                    -- 730 rows
SELECT DISTINCT(date_key) FROM dim_date ORDER BY date_key ASC;  -- 730 rows
```
These two queries **confirm each other**: the row count (730) matches the
count of unique `date_key` values (730) → no duplicate primary keys.
`date_key` itself is just a random number (not a real date representation),
the actual date lives in the `full_date` column.

### 2.4 Checking referential integrity (anti-join, x4)
```sql
SELECT f.sale_id FROM fact_sales f
LEFT JOIN dim_customer c ON f.customer_key = c.customer_key
WHERE c.customer_key IS NULL;
-- the same pattern is repeated for dim_date, dim_product, dim_store
```
This continues directly from the FK exploration in 2.3: using `LEFT JOIN` +
`WHERE ... IS NULL` (the *anti-join* pattern) to find `fact_sales` rows whose
FK **has no match** in the dimension table. Result: **0 rows across all four
checks** → structural correlation between tables is 100% valid, safe for
every `JOIN` in the queries that follow.

### 2.5 Creating a combined view
```sql
CREATE OR REPLACE VIEW fact_sales_clean AS
SELECT f.sale_id, ..., p.category, p.subcategory
FROM fact_sales f
JOIN dim_product p ON f.product_key = p.product_key;
```
Since FK integrity is already proven safe (2.4), it's now safe to create a
*view* that attaches `category`/`subcategory` from `dim_product` onto every
fact row — so subsequent analysis queries don't need to `JOIN` repeatedly.

### 2.6 Testing the new view
```sql
SELECT * FROM fact_sales_clean;   -- 60,000 rows
```
The resulting row count (60,000) exactly matches the original `fact_sales`
row count → proving the `fact_sales` ↔ `dim_product` relationship is purely
*many-to-one*, with no duplication from the join (no fan-out).

### 2.7 Fixing `category` in the fact table
```sql
UPDATE fact_sales f
SET category = p.category
FROM dim_product p
WHERE f.product_key = p.product_key
  AND f.category IS DISTINCT FROM p.category;
```
Where the view (2.5) pulls `category` from `dim_product`, here `fact_sales`'s
own `category` column is **overwritten** to match `dim_product` — only for
rows where the value differs (`IS DISTINCT FROM` is the `NULL`-safe version
of `<>`).

### 2.8 Fixing `quarter`
```sql
UPDATE dim_date
SET quarter = 'Q' || CEIL(EXTRACT(MONTH FROM full_date) / 3.0)::INT
WHERE quarter <> 'Q' || CEIL(EXTRACT(MONTH FROM full_date) / 3.0)::INT;
```
Moving to the `dim_date` table, already explored in 2.3. `EXTRACT(MONTH ...)`
gets the month number (1–12), divides by 3, then rounds up (`CEIL`) to map
to a quarter (Jan–Mar→Q1, etc.), overwriting only rows where the quarter is
wrong relative to `full_date`.

### 2.9 Fixing `is_weekend`
```sql
UPDATE dim_date
SET is_weekend = (day_of_week IN ('Saturday', 'Sunday'))
WHERE is_weekend <> (day_of_week IN ('Saturday', 'Sunday'));
```
Same pattern as 2.8, but for the `is_weekend` column, derived from
`day_of_week`. Both UPDATEs (2.8–2.9) clean up `dim_date` before it's used
for time-based aggregation later (2.21, 2.22).

### 2.10 Testing the `revenue` formula
```sql
SELECT sale_id, quantity, unit_price, discount_pct, revenue,
       ROUND(quantity * unit_price * (1 - discount_pct), 2) AS expected_revenue,
       ROUND(revenue - quantity * unit_price * (1 - discount_pct), 2) AS diff
FROM fact_sales
WHERE ABS(revenue - quantity * unit_price * (1 - discount_pct)) > 0.05
ORDER BY ABS(...) DESC;
```
This tests the **mathematical correlation** between `revenue` and the
combination `quantity × unit_price × (1 − discount_pct)`. Result: 59,947 of
60,000 rows (99.9%) don't match — meaning `revenue` in this dataset is
**not** computed from that formula, so it can't be used as a cross-check for
`revenue`.

### 2.11 Checking variation in `discount_pct`
```sql
SELECT COUNT(DISTINCT discount_pct) AS distinct_discounts, MIN(discount_pct), MAX(discount_pct)
FROM fact_sales;
```
Following up on the suspicion from 2.10: if the revenue formula doesn't
match, maybe the discount varies unexpectedly? Turns out not — the result is
`1 | 0.35 | 0.35`, meaning all 60,000 rows have the exact **same** discount
(35%), so this column has no analytical value.

### 2.12 Finding duplicate emails
```sql
SELECT email, COUNT(*) AS n, STRING_AGG(customer_key::TEXT, ', ') AS customer_keys
FROM dim_customer
GROUP BY email
HAVING COUNT(*) > 1
ORDER BY n DESC;
```
Moving to `dim_customer`. `GROUP BY email HAVING COUNT(*) > 1` finds emails
used by more than one `customer_key` — 15 duplicate emails found (likely the
same customer recorded twice).

### 2.13 Standardizing customer text fields
```sql
UPDATE dim_customer SET
    customer_name = TRIM(customer_name),
    email = LOWER(TRIM(email)),
    city = TRIM(city),
    country = UPPER(TRIM(country));
```
After finding duplicates (2.12), text formatting is cleaned up (trim
whitespace, standardize casing) across all 2,000 rows. **Note:** this step
tidies formatting but **doesn't merge** the 15 duplicate pairs found in 2.12.

### 2.14 Validating `fact_sales` value ranges
```sql
SELECT * FROM fact_sales
WHERE quantity <= 0 OR unit_price <= 0 OR revenue <= 0 OR discount_pct NOT BETWEEN 0 AND 1;
```
Back to `fact_sales` for a final check before moving to statistical
analysis: confirming there are no negative/zero/out-of-range values. Result:
0 rows — the numeric data is safe to use for the statistical calculations
that follow.

### 2.15 Combined descriptive statistics
```sql
SELECT 'quantity' AS metric, MIN(...), MAX(...), ROUND(AVG(...),4) AS mean,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY quantity) AS median,
       MODE() WITHIN GROUP (ORDER BY quantity) AS mode,
       ROUND(STDDEV(...),4), ROUND(VARIANCE(...),4)
FROM fact_sales
UNION ALL
SELECT 'unit_price', ... FROM fact_sales
UNION ALL
SELECT 'revenue', ... FROM fact_sales
UNION ALL
SELECT 'discount_pct', ... FROM fact_sales;
```
Since the data is already validated as clean (2.14), full statistics (min,
max, mean, median, mode, stddev, variance) are now computed for 4 numeric
columns at once, combined into one tidy table via `UNION ALL`. The
`discount_pct` stddev/variance of 0 **re-confirms** the finding from 2.11.

### 2.16 Best-selling category (window function)
```sql
SELECT category, cnt FROM (
    SELECT p.category, COUNT(*) AS cnt,
           RANK() OVER (ORDER BY COUNT(*) DESC) AS rnk
    FROM fact_sales f JOIN dim_product p ON f.product_key = p.product_key
    GROUP BY p.category
) t WHERE rnk = 1;
```
Moving from general statistics (2.15) to the first business question: which
category sells most often? `RANK() OVER (...)` is used in a subquery to rank
them, then `WHERE rnk = 1` grabs only the winner. Result: **Electronics**,
21,813 transactions.

### 2.17 Revenue quartiles
```sql
SELECT
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY revenue) AS q1,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY revenue) AS median,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY revenue) AS q3
FROM fact_sales;
```
Deepens the `revenue` statistics from 2.15 with full quartiles
(Q1/median/Q3) — useful for detecting outliers via IQR. Result: 27.53 / 47.90
/ 77.30.

### 2.18 Revenue by region x category x quarter
```sql
SELECT s.region, p.category, d.quarter,
       COUNT(*) AS num_sales, SUM(f.revenue) AS total_revenue,
       ROUND(AVG(f.revenue), 2) AS avg_revenue,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY f.revenue) AS median_revenue
FROM fact_sales f
JOIN dim_store   s ON f.store_key = s.store_key
JOIN dim_product p ON f.product_key = p.product_key
JOIN dim_date    d ON f.date_key = d.date_key
GROUP BY s.region, p.category, d.quarter
ORDER BY total_revenue DESC;
```
This is where **structural correlation** (2.4) and the `dim_date` cleanup
results (2.8–2.9) start being used together: three dimension tables
(`dim_store`, `dim_product`, `dim_date`) are all `JOIN`ed to `fact_sales` at
once to break revenue down by region/category/quarter combination.

### 2.19 Top 10 customers
```sql
SELECT c.customer_key, c.customer_name, c.segment, c.country,
       COUNT(*) AS orders, SUM(f.revenue) AS lifetime_revenue,
       ROUND(AVG(f.revenue), 2) AS avg_order_value
FROM fact_sales f
JOIN dim_customer c ON f.customer_key = c.customer_key
GROUP BY c.customer_key, c.customer_name, c.segment, c.country
ORDER BY lifetime_revenue DESC
LIMIT 10;
```
The angle shifts from "product/region" (2.18) to "customer" — using
`dim_customer`, already cleaned in 2.13. `GROUP BY` per customer, then
sorted descending by total lifetime revenue.

### 2.20 Best-selling products + margin
```sql
SELECT p.product_key, p.product_name, p.category,
       SUM(f.quantity) AS units_sold, SUM(f.revenue) AS total_revenue,
       ROUND(AVG(f.revenue / NULLIF(f.quantity,0)), 2) AS avg_revenue_per_unit,
       p.unit_cost, p.list_price,
       ROUND(p.list_price - p.unit_cost, 2) AS unit_margin
FROM fact_sales f
JOIN dim_product p ON f.product_key = p.product_key
GROUP BY p.product_key, p.product_name, p.category, p.unit_cost, p.list_price
ORDER BY total_revenue DESC
LIMIT 20;
```
Continuing from "best-selling category" (2.16) to a more detailed level:
individual products, including estimated margin (`list_price - unit_cost`).
Important finding: many top-selling products have **negative** margin —
indicating a problem with the `dim_product` data (similar to the `revenue`
finding in 2.10).

### 2.21 Weekday vs weekend
```sql
SELECT d.is_weekend, COUNT(*) AS num_sales, SUM(f.revenue) AS total_revenue,
       ROUND(AVG(f.revenue), 2) AS avg_revenue
FROM fact_sales f
JOIN dim_date d ON f.date_key = d.date_key
GROUP BY d.is_weekend;
```
Directly uses the `is_weekend` fix from 2.9. Result: average revenue is
nearly identical (weekday $57.52 vs weekend $57.46) — no strong weekly
seasonal pattern, only volume differs (weekday has ~2x more transactions).

### 2.22 Monthly trend
```sql
SELECT d.month_name, d.quarter, COUNT(*) AS num_sales, SUM(f.revenue) AS total_revenue
FROM fact_sales f
JOIN dim_date d ON f.date_key = d.date_key
GROUP BY d.month_name, d.quarter
ORDER BY MIN(d.full_date);
```
Continues the time analysis from 2.21, but at monthly granularity, sorted by
`MIN(full_date)` (not alphabetically) to stay chronological. Note:
`month_name` itself was never fixed (unlike `quarter` in 2.8), so the
ordering/grouping of months here may still carry inherited inconsistency.

### 2.23 Store ranking per region
```sql
SELECT s.region, s.store_name, s.store_type,
       SUM(f.revenue) AS total_revenue,
       RANK() OVER (PARTITION BY s.region ORDER BY SUM(f.revenue) DESC) AS rank_in_region
FROM fact_sales f
JOIN dim_store s ON f.store_key = s.store_key
GROUP BY s.region, s.store_name, s.store_type;
```
Combines the `RANK()` technique from 2.16 with `PARTITION BY` — so the rank
is recalculated **per region**, not a global rank. Result: 40 stores, each
with its own rank within its region.

### 2.24 Behavior by customer segment
```sql
SELECT c.segment,
       COUNT(DISTINCT c.customer_key) AS num_customers,
       COUNT(*) AS num_orders,
       ROUND(AVG(f.revenue), 2) AS avg_order_value,
       ROUND(SUM(f.revenue) / COUNT(DISTINCT c.customer_key), 2) AS revenue_per_customer
FROM fact_sales f
JOIN dim_customer c ON f.customer_key = c.customer_key
GROUP BY c.segment
ORDER BY revenue_per_customer DESC;
```
Extends the customer analysis (2.19) to segment level
(`Consumer`/`Corporate`/`Home Office`). `COUNT(DISTINCT ...)` ensures a
customer with many transactions isn't counted multiple times when computing
customer count. Result: all three segments are nearly identical
(~$1,710–$1,733 per customer) — no segment stands out.

### 2.25 Statistical correlation between price and quantity
```sql
SELECT CORR(unit_price, quantity) AS price_qty_correlation FROM fact_sales;
```
Closing query, and this is what explicitly measures the **statistical
correlation** referenced in §1: `CORR()` computes the Pearson correlation
coefficient between `unit_price` and `quantity`. Result: **0.0077** — nearly
zero, meaning unit price **doesn't influence** the quantity customers buy in
this dataset (no detectable price elasticity).

---

## 3. Conclusion

1. **Structural correlation between tables is 100% valid** — every foreign
   key in `fact_sales` (`customer_key`, `date_key`, `product_key`,
   `store_key`) has a valid match in its respective dimension table, with no
   orphan rows.
2. **Statistical correlation between price and quantity is nearly
   nonexistent** (`CORR` ≈ 0.0077) — customers don't buy less when price
   rises or more when price falls. This is a strong signal the dataset is
   synthetic/random rather than real transaction data, which usually shows
   price elasticity.
3. **Derived columns in `dim_date` were initially inconsistent** —
   `quarter` and `is_weekend` have been fixed from `full_date`/`day_of_week`,
   but **`month_name` is still unfixed**, so monthly analysis (2.22) can be
   biased.
4. **`revenue` doesn't follow the formula
   `quantity × unit_price × (1 − discount_pct)`** (99.9% of rows differ) and
   **`discount_pct` is a constant 0.35 across all data** — neither column can
   validate the other, so `revenue` must be treated as an independent number
   (ground truth), not a calculated result.
5. **15 duplicate customer emails** in `dim_customer` — formatting has been
   cleaned up (trim/lower/upper) but they have **not been merged** into a
   single `customer_key`.
6. **Many products have negative margin**
   (`list_price` < `unit_cost`) among the top-revenue products — likely
   indicates `dim_product` data is also problematic/synthetic, so margin
   metrics shouldn't be used for real business decisions without verifying
   the data source.
7. **Business findings that remain valid to report:** the best-selling
   category is Electronics (21,813 transactions), East region + Electronics
   + Q3 is the highest-revenue combination, and revenue per customer is
   relatively even across all three segments (Consumer/Corporate/Home
   Office) — no segment is significantly more profitable.

**Follow-up recommendation:** don't use `discount_pct`, the manual revenue
formula, or product margin as the basis for decisions before the data source
is revalidated; fix `month_name`; merge the 15 duplicate customer pairs; and
move the database credentials out of the notebook and into an environment
variable immediately.
