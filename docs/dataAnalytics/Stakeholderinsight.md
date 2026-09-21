# Business Insight for Stakeholders — Retail Sales

This document contains a set of **ready-to-use queries for stakeholder
reports/presentations** (not the technical team) — the focus isn't data
validation, but answers to business questions: how big is this business,
where is it trending, who/what contributes the most, and where are the
opportunities/risks. Each section contains: **who the insight is for & why it
matters**, its **SQL syntax**, then a **summarized result &
recommended action**.

Data basis: `fact_sales` (60,000 transactions) + 4 dimension tables
(`dim_customer`, `dim_date`, `dim_product`, `dim_store`). See `readmechat.md`
for technical detail on schema & data quality.

---

## 1. Executive Summary (Key KPIs)

**Who it's for:** management/executives who need a business overview in one
screen.
**Why it matters:** these are the standard opening numbers in every business
report — total transactions, active customer count, total revenue, and
average transaction value.

```sql
SELECT
    COUNT(DISTINCT sale_id)     AS total_transactions,
    COUNT(DISTINCT customer_key) AS total_customers,
    ROUND(SUM(revenue), 2)      AS total_revenue,
    ROUND(AVG(revenue), 2)      AS avg_transaction_value
FROM fact_sales;
```
- `COUNT(DISTINCT ...)` counts unique values (transactions & customers), not
  just row count.
- `SUM(revenue)` sums all revenue; `AVG(revenue)` = average value per
  transaction (similar to the *Average Order Value* concept).

**Result:**

| total_transactions | total_customers | total_revenue | avg_transaction_value |
|---|---|---|---|
| 60,000 | 2,000 | **$3,450,000** | $57.50 |

**Insight:** the average customer transacts ~30 times, with an average
transaction value of $57.50.

---

## 2. Monthly Revenue Trend & Month-over-Month Growth

**Who it's for:** management/finance teams monitoring business momentum.
**Why it matters:** total revenue alone isn't enough — stakeholders need to
know the **trend direction**: up, down, or seasonal. The growth (%) column
directly answers "is this month better than last month or not?".

```sql
WITH monthly AS (
    SELECT DATE_TRUNC('month', d.full_date) AS month,
           SUM(f.revenue) AS total_revenue
    FROM fact_sales f
    JOIN dim_date d ON f.date_key = d.date_key
    GROUP BY DATE_TRUNC('month', d.full_date)
)
SELECT
    TO_CHAR(month, 'YYYY-MM') AS month,
    total_revenue,
    ROUND(
        100.0 * (total_revenue - LAG(total_revenue) OVER (ORDER BY month))
        / NULLIF(LAG(total_revenue) OVER (ORDER BY month), 0)
    , 2) AS growth_pct
FROM monthly
ORDER BY month;
```
- `DATE_TRUNC('month', full_date)` rounds the date to the start of the month
  — used as a reliable time source (rather than the raw `month_name`/
  `quarter` from `dim_date`, which per the technical audit has
  inconsistencies — see `readmechat.md`).
- `LAG(total_revenue) OVER (ORDER BY month)` pulls the **previous month's**
  revenue value for the row being processed — this is the key to computing
  MoM growth.
- `NULLIF(..., 0)` prevents a division-by-zero error.

**Result (24 months, Jan 2024 - Dec 2025), excerpt:**

| month | total_revenue | growth_pct |
|---|---|---|
| 2024-03 | 209,782.56 | **+57.19%** |
| 2024-04 | 116,971.26 | -44.24% |
| 2025-10 | 169,054.39 | **+55.23%** |
| 2025-11 | 117,660.79 | -30.40% |

**Insight:** revenue fluctuates sharply month-to-month (swinging >40-55%
repeatedly) with no clear seasonal pattern (compare March's sharp rise in
2024, which isn't consistent in the same month the following year). This is
an **unusual** pattern for real retail data (which usually has seasonality
like holidays/year-end) — most likely because this dataset is
synthetic/random. **Recommendation:** don't use monthly trends in this
dataset for stock planning or seasonal campaign decisions until validated
against real production data.

---

## 3. Revenue Contribution by Product Category

**Who it's for:** merchandising/product & marketing teams.
**Why it matters:** shows which category is the "main engine" of revenue,
the basis for promotional budget allocation and stocking decisions.

```sql
SELECT
    category,
    SUM(revenue) AS total_revenue,
    ROUND(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 2) AS pct_of_total
FROM fact_sales_clean
GROUP BY category
ORDER BY total_revenue DESC;
```
- Uses `fact_sales_clean` (a view whose category is already cleaned, synced
  with `dim_product`) — not the raw `fact_sales.category`, which per the
  technical audit is out of sync in 72.5% of rows.
- `SUM(SUM(revenue)) OVER ()` is a **window function on top of a GROUP BY
  result** — a trick to sum the grand total without a separate query, used
  here as the divisor to get percentage contribution.

**Result:**

| category | total_revenue | pct_of_total |
|---|---|---|
| Electronics | 1,252,525.97 | **36.31%** |
| Home | 947,668.83 | 27.47% |
| Grocery | 858,074.81 | 24.87% |
| Apparel | 391,730.39 | 11.35% |

**Insight:** Electronics is the largest category (>1/3 of revenue), Apparel
is the smallest. **Recommendation:** prioritize stock availability & ad
budget toward Electronics, and evaluate whether Apparel needs a
bundling/discount strategy to boost its contribution.

---

## 4. Regional Performance

**Who it's for:** regional sales/operations teams.
**Why it matters:** shows which region contributes the most revenue — the
basis for expansion decisions, sales team placement, or investigating
underperforming regions.

```sql
SELECT
    s.region,
    COUNT(*)               AS transaction_count,
    SUM(f.revenue)          AS total_revenue,
    ROUND(AVG(f.revenue),2) AS avg_transaction
FROM fact_sales f
JOIN dim_store s ON f.store_key = s.store_key
GROUP BY s.region
ORDER BY total_revenue DESC;
```
- `JOIN` with `dim_store` to get the `region` for each transaction (this
  info isn't directly in `fact_sales`).
- `GROUP BY s.region` collapses 60,000 transactions into 4 rows (one per
  region).

**Result:**

| region | transaction_count | total_revenue | avg_transaction |
|---|---|---|---|
| East | 25,390 | **1,457,512.42** | 57.40 |
| West | 14,852 | 852,170.33 | 57.38 |
| South | 10,610 | 613,301.16 | 57.80 |
| North | 9,148 | 527,016.09 | 57.61 |

**Insight:** East dominates (42% of total transactions), but the average
transaction value across regions is **nearly identical** (~$57.4-57.8) —
meaning East leads because of transaction **volume**, not because customers
there spend more per transaction. **Recommendation:** North & South are
candidates for customer acquisition/new store expansion programs, since
their volume is far smaller despite comparable transaction value.

---

## 5. Highest & Lowest Performing Stores

**Who it's for:** store operations managers/retail ops.
**Why it matters:** identifies top-performing stores (to study and
replicate their practices) and underperforming stores (to audit/fix).

```sql
WITH store_rev AS (
    SELECT s.store_key, s.store_name, s.region, s.store_type,
           SUM(f.revenue) AS total_revenue
    FROM fact_sales f
    JOIN dim_store s ON f.store_key = s.store_key
    GROUP BY s.store_key, s.store_name, s.region, s.store_type
)
(SELECT * FROM store_rev ORDER BY total_revenue DESC LIMIT 5)
UNION ALL
(SELECT * FROM store_rev ORDER BY total_revenue ASC LIMIT 5);
```
- `WITH store_rev AS (...)` is a **CTE** (Common Table Expression) —
  computes total revenue per store once, then uses it twice (to get the top
  5 and bottom 5) without rewriting the `JOIN`/`GROUP BY` logic.
- `UNION ALL` combines the two results (top 5 and bottom 5) into a single
  table for direct comparison.

**Result (excerpt):**

| Rank | store_name | region | total_revenue |
|---|---|---|---|
| #1 highest | Silver Cloud Inc | North | 91,347.49 |
| #2 highest | Summit Works Collective | South | 90,342.51 |
| ... | ... | ... | ... |
| #5 lowest | Ever Systems Solutions | South | 80,662.18 |

**Insight:** the gap between the best and weakest stores is relatively small
(±12%), no store is severely underperforming — store performance is fairly
even nationwide. **Recommendation:** since the gap is small, focus evaluation
on *store_type* (Flagship/Standard/Outlet) and region rather than chasing
one specific problem store.

---

## 6. Top 10 High-Value Customers (VIP/Loyalty Candidates)

**Who it's for:** CRM/customer success & loyalty marketing teams.
**Why it matters:** high-value customers are the most important asset to
retain — this list forms the basis for VIP programs, retention, or personal
outreach.

```sql
SELECT c.customer_key, c.customer_name, c.segment, c.country,
       COUNT(*) AS order_count,
       ROUND(SUM(f.revenue), 2) AS total_revenue
FROM fact_sales f
JOIN dim_customer c ON f.customer_key = c.customer_key
GROUP BY c.customer_key, c.customer_name, c.segment, c.country
ORDER BY total_revenue DESC
LIMIT 10;
```
- `JOIN` to `dim_customer` to get the customer's name/segment/country
  (business identity, not just a numeric ID).
- `ORDER BY total_revenue DESC LIMIT 10` — the standard "top-N" pattern in
  SQL.

**Result (top 3):**

| customer_name | segment | country | order_count | total_revenue |
|---|---|---|---|---|
| Andreas Meyer | Corporate | BR | 46 | 3,481.83 |
| Ming Luo | Consumer | US | 40 | 3,196.01 |
| Sandra Lewis | Home Office | BR | 46 | 2,999.56 |

**Insight:** top customers come from different segments (Corporate,
Consumer, Home Office) and different countries — not concentrated in one
particular customer type. **Recommendation:** use this list as a starting
point for loyalty/exclusive discount programs, but personalize per segment
since their profiles vary.

---

## 7. Customer Revenue Concentration ("Eggs in One Basket" Risk Analysis)

**Who it's for:** senior management/finance, to assess revenue dependency
risk.
**Why it matters:** if the majority of revenue comes from a small handful of
customers, the business is at significant risk if they leave (commonly
called the 80/20 pattern or *revenue concentration risk*). This groups
customers into 10 groups (deciles) based on revenue contribution.

```sql
WITH cust AS (
    SELECT customer_key, SUM(revenue) AS rev
    FROM fact_sales
    GROUP BY customer_key
),
ranked AS (
    SELECT customer_key, rev,
           NTILE(10) OVER (ORDER BY rev DESC) AS decile
    FROM cust
)
SELECT decile,
       COUNT(*) AS customer_count,
       ROUND(SUM(rev), 2) AS total_revenue,
       ROUND(100.0 * SUM(rev) / SUM(SUM(rev)) OVER (), 2) AS pct_revenue
FROM ranked
GROUP BY decile
ORDER BY decile;
```
- `NTILE(10) OVER (ORDER BY rev DESC)` divides all customers (already
  sorted from highest to lowest revenue) into **10 equal-sized groups**
  (200 customers each) — decile 1 = the top 10% of customers by revenue.
- The outer query summarizes each decile into a total & percentage
  contribution.

**Result:**

| decile (top 10% -> bottom) | customer_count | pct_revenue |
|---|---|---|
| 1 (highest) | 200 | 14.23% |
| 2 | 200 | 12.36% |
| 5 (middle) | 200 | 10.22% |
| 9 | 200 | 7.63% |
| 10 (lowest) | 200 | 6.23% |

**Insight:** the top 10% of customers contribute only **14.23%** of total
revenue (not ~50-80% like the classic Pareto pattern in real retail) — the
distribution of revenue across customers is **relatively even**, so the risk
of losing one or a few large customers to the overall business is **low**.
**Recommendation:** retention strategy can be focused evenly across the
whole customer base, rather than just on a handful of "whale customers".

---

## 8. Shopping Behavior by Customer Segment

**Who it's for:** marketing segmentation team.
**Why it matters:** answers "which customer segment (Consumer/Corporate/Home
Office) is most profitable per head?" — the basis for per-segment campaign
prioritization.

```sql
SELECT c.segment,
       COUNT(DISTINCT c.customer_key) AS customer_count,
       COUNT(*)                       AS order_count,
       ROUND(AVG(f.revenue), 2)       AS avg_order_value,
       ROUND(SUM(f.revenue) / COUNT(DISTINCT c.customer_key), 2) AS revenue_per_customer
FROM fact_sales f
JOIN dim_customer c ON f.customer_key = c.customer_key
GROUP BY c.segment
ORDER BY revenue_per_customer DESC;
```
- `COUNT(DISTINCT c.customer_key)` vs `COUNT(*)` — the first counts
  **unique customers**, the second counts **orders** (one customer can order
  multiple times); both need to be distinguished for the "per customer"
  metric to be accurate.

**Result:**

| segment | customer_count | avg_order_value | revenue_per_customer |
|---|---|---|---|
| Home Office | 336 | 57.33 | **1,733.46** |
| Consumer | 1,065 | 57.48 | 1,730.54 |
| Corporate | 599 | 57.63 | 1,710.40 |

**Insight:** all three segments are nearly identical in value (difference
<1.5%) — no segment is significantly more profitable per customer.
**Recommendation:** since there's no meaningful difference, marketing budget
allocation decisions should be based on **segment size** (Consumer is
largest, 1,065 customers) for maximum reach, rather than assuming one
segment is "more premium".

---

## 9. Weekday vs Weekend Pattern

**Who it's for:** operations teams (staff scheduling) & marketing (promo
timing).
**Why it matters:** determines when to add store staffing or schedule
promotional campaigns.

```sql
SELECT d.is_weekend,
       COUNT(*)                AS transaction_count,
       SUM(f.revenue)           AS total_revenue,
       ROUND(AVG(f.revenue), 2) AS avg_transaction
FROM fact_sales f
JOIN dim_date d ON f.date_key = d.date_key
GROUP BY d.is_weekend;
```

**Result:**

| is_weekend | transaction_count | total_revenue | avg_transaction |
|---|---|---|---|
| False (weekday) | 39,974 | 2,299,238.37 | 57.52 |
| True (weekend) | 20,026 | 1,150,761.63 | 57.46 |

**Insight:** weekday transaction volume is roughly 2x weekend volume
(consistent with 5 weekdays vs 2 weekend days), but average transaction
value is the same. **Recommendation:** no special weekend pricing strategy
is needed; keep operational focus (staff/stock) proportional to the 5:2 day
split.

---

## 10. Best-Selling Products (Top 20 by Revenue)

**Who it's for:** merchandising & stock/inventory management teams.
**Why it matters:** knowing which products drive the most revenue is
important for ensuring stock availability and choosing featured products in
promotional materials.

```sql
SELECT p.product_name, p.category,
       SUM(f.quantity)        AS units_sold,
       ROUND(SUM(f.revenue),2) AS total_revenue
FROM fact_sales f
JOIN dim_product p ON f.product_key = p.product_key
GROUP BY p.product_name, p.category
ORDER BY total_revenue DESC
LIMIT 20;
```
> **Note:** margin (`list_price - unit_cost`) is deliberately **not**
> included here, unlike the technical version in `readmechat.md` — the data
> audit found many top products with negative margin, indicating
> `dim_product.unit_cost`/`list_price` has issues. Don't share margin
> figures with stakeholders before the data team verifies the source.

**Insight:** the Electronics & Home categories dominate the top-20
best-seller list (consistent with the finding in §3). **Recommendation:**
use this list as the primary reference for next-season stock planning and
catalog/promotional materials.

---

## 11. Data Limitations (Must Read Before Presenting)

Several metrics **must not** be presented to stakeholders as business fact,
because they've proven to be data-quality issues (full detail in
`readmechat.md`):

| Don't use | Reason |
|---|---|
| `discount_pct` as a discount insight | Constant at 35% across all 60,000 rows — no real variation. |
| Manual formula `revenue = qty x price x (1-discount)` | 99.9% of the data doesn't match this formula — `revenue` is an independent number. |
| Product margin (`list_price - unit_cost`) | Many top-selling products have negative margin — indicates `dim_product` data isn't realistic. |
| Customer name as a unique identity | 15 emails are used by more than one `customer_key` (likely duplicate customer records). |
| Monthly trend (§2) as a seasonal pattern | >40-55% MoM fluctuation with no repeating pattern year-over-year — likely random/synthetic data. |

---

## 12. Conclusion for Stakeholders

1. **Business scale:** 60,000 transactions from 2,000 customers, total
   revenue $3,450,000, average $57.50/transaction.
2. **Electronics is the core category** (36% of total revenue) — priority
   for stock & promotion.
3. **East is the highest-volume region**, but average transaction value is
   comparable across all regions — growth opportunity lies in **volume** in
   North/South, not in raising transaction value.
4. **Customer concentration risk is low** — revenue is spread fairly evenly
   (the top 10% of customers contribute only 14% of revenue), so the
   business isn't overly dependent on a handful of large customers.
5. **No meaningful difference between customer segments** (Consumer/
   Corporate/Home Office) or between weekday/weekend in terms of transaction
   value — resource allocation decisions should be based on **volume/group
   size**, not assumptions about which group is "more valuable".
6. **Before any strategic decision** (pricing, margin, discount targets) is
   made from this dataset, the data team needs to revalidate the quality of
   the `discount_pct`, `revenue`, and `unit_cost`/`list_price` columns — see
   §11.

**Primary recommended actions:** (a) strengthen Electronics stock &
marketing, (b) run customer acquisition programs in the North/South regions,
(c) start a retention program spread evenly across the customer base (not
just top spenders), (d) hold off on margin/discount-based decisions until
that data is revalidated by the data team.
