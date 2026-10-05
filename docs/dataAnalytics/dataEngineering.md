# Data Engineering — Retail Analytics Platform

**What this document is:** the complete, step-by-step account of everything that
was built and done in `etl/` — the environment, the four-stage pipeline, the
eBay price scraping, and the manual pricing repair that ran on top of it.
Written as a working reference for the Data Engineer role, not as a tutorial.

**Location of the code:** `etl/` — driver notebook `etl/main_pipeline.ipynb`,
SQL stage functions, Python helpers, two scrapers.

---

## 0. The Big Picture

```
data/*.csv ──► public  ──► staging ──► transformed ──► clean
 (Misata,       (reset     (etl.extract)  (etl.transform)  (etl.load())
  63,170 rows)   each run)
                                    │
                                    └──► main_pipeline.ipynb
                                         cells 8–70: pricing repair
                                         (brands, eBay prices, unit_cost,
                                          retail_price, revenue)
```

Two layers of work live here:

1. **The repeatable pipeline** — 9 documented data-quality issues, each with a
   decision, a rule table, and a gate that fails the run if the fix regresses.
2. **A one-off pricing rebuild** — the source prices were unusable, so real
   market prices were scraped from eBay and written back into `public`.
   (Full detail in [`PricingIssueFix.md`](./PricingIssueFix.md).)

The split matters: layer 1 is re-runnable, layer 2 is a correction applied
directly to the `public` tables and will be wiped if step 0 (CSV reset) is
re-run.

---

## 1. Environment & Connection

### Docker

- `compose.yaml` — `postgres:16` service (`retailspg`, port 5432, named volume
  `retailspg-data`) plus an `etl` service behind the `etl` profile that copies
  `etl/` into the image and runs the SQL files with `psql` in order
  (extract → transform → load).
- Secrets are **files, never env vars in git**: `secrets/database_url.txt`,
  `secrets/postgres_password.txt`, mounted at `/run/secrets/*`.
- `docker/etl.Dockerfile` builds on `postgres:16-alpine`, sets
  `RAW_SALES_CSV=/app/data/raw/raw_sales.csv`.

```bash
docker compose up -d                          # database only
docker compose --profile etl run --rm etl     # run the whole pipeline in Docker
```

### Two ways to get a connection (both exist on purpose)

| File | Used by | Resolution order |
|---|---|---|
| `connectdb.py` | the notebook | `secrets/database_url.txt` (walking up from cwd) → `DATABASE_URL` env |
| `secretsget.py` | containerised scripts | `/run/secrets/<name>` → env var → local `secrets/<name>.txt` |

`secretsget.get_secret(name)` reads Docker's `/run/secrets` first so the same
code works inside the container and on the laptop; both `strip()` the trailing
newline and fail loudly with a message naming all three places it looked.

### Python environment

`retailAnalytics/` is a venv (Python 3.14.7, matches the notebook kernel
`retailAnalytics (3.14.7)`). `etl/requirements.txt` is a fully pinned freeze —
pandas 3.0.5, SQLAlchemy 2.0.52, psycopg2-binary 2.9.12, jupysql 0.11.1,
matplotlib-inline, ipykernel, numpy.

### Source data

`data/` holds the Misata-generated star schema (public domain, CC0):
`dim_date` 730, `dim_product` 400, `dim_customer` 2,000, `dim_store` 40,
`fact_sales` 60,000 — 63,170 rows total. `data/INTEGRITY.txt` records the
independent DuckDB verification: zero orphans on all four joins, zero duplicate
dimension keys, category revenue share exactly 42/26/20/12 %, monthly revenue on
a declared two-year curve. `schema.sql` + `schema.yaml` are the generator spec.

---

## 2. Step 0 — Reset `public` From the CSVs (notebook cells 1–3)

The notebook's first real action, guarded by `CONFIRM_RESET = True`:

1. `DROP SCHEMA IF EXISTS clean, transformed, staging, etl CASCADE;`
2. Drop the hand-edited artefacts (`public.fact_sales_clean`,
   `customer_dedup_map`, all five base tables).
3. `SET search_path TO public;` + `schema.sql` → recreates the empty star schema.
4. `COPY public.<table> FROM STDIN WITH CSV HEADER` for `dim_date`,
   `dim_product`, `dim_customer`, `dim_store`, `fact_sales`.

Helper functions defined here and used for the rest of the notebook:

- `run_file(path)` — executes a `.sql` file on a raw psycopg2 connection.
- `query(sql)` — `pd.read_sql` helper; every SELECT in the notebook goes
  through it.
- `LOAD_RAW_SALES = True` — separately `COPY`s the original
  `sale_id, category` pairs into `staging.raw_sales`, because those columns get
  overwritten later and the originals are needed for the audit.

---

## 3. Step 1 — `rules.sql`: Decide Every Question Before Touching Data

Run **once**, before the stages; safe to re-run. Creates the `etl` schema and
four rule tables. The design rule: **seeds only insert when the table is
empty** (`WHERE NOT EXISTS` / `ON CONFLICT DO NOTHING`) so hand-edits are never
overwritten.

| Table | Solves | How |
|---|---|---|
| `etl.product_category_map` | Issue 2 | `product_name → category`. Seeded by name: any name that has a `Home` row anywhere is `Home`, everything else `Electronics` → **42 names mapped** |
| `etl.quantity_rules` | Issue 1 | `category + name_pattern → pack/unit + units_per_pack`. `Electronics '%4-Pack%'` = 4 units per pack; everything else 1 unit |
| `etl.pricing_rules` | Issues 5, 9 | `category + name_pattern → unit_cost, list_price, source`, with `CHECK (list_price >= unit_cost)` so a negative margin is impossible to insert. Seeded as an explicit **PLACEHOLDER**: median source `unit_cost` per name × 1.60 |
| `etl.decision_log` | 4, 5, 2, 8, 7 | One row per issue: `decision` ∈ accept/fix/reject + the reasoning |

`etl.decision_log` verbatim:

| # | Decision | Rationale |
|---|---|---|
| 4 | accept | `discount_pct` is a constant 0.35 everywhere — no variation to clean; documented as a flat-rate assumption |
| 5 | fix | 78 % of source products had `unit_cost > list_price` (generator defect, not clearance). Prices come from `etl.pricing_rules` |
| 2 | accept | `fact_sales` keeps its original 4 categories (42/26/20/12); `dim_product.category` keeps original labels; `product_group` holds the name-based classification |
| 8 | reject | Do **not** derive `fact_sales.category` from `dim_product` — that would delete Apparel/Grocery. Flag the disagreement in `category_matches_product` instead |
| 7 | accept | Official revenue = `round(quantity * unit_price * (1 - discount_pct), 2)`; the source column is kept for audit only |

---

## 4. Step 2 — `extract.sql`: Copy, Don't Transform

`etl.extract()` — one call, idempotent:

1. `CREATE SCHEMA IF NOT EXISTS staging;`
2. Drop and recreate `staging.dim_date / dim_product / dim_customer /
   dim_store / fact_sales` as `CREATE TABLE AS TABLE public.<table>` — a
   **structural copy**, no logic, so the stage is a true snapshot.
3. `TRUNCATE staging.raw_sales` (the audit pair table; loaded by the notebook
   via `COPY`).

`etl.validate_raw_sales()` — `RAISE EXCEPTION` if `raw_sales` is empty or has
duplicate `sale_id`. Called from inside `transform()`.

Note recorded in the file: the CSV import cannot happen inside PostgreSQL, so
`raw_sales` is loaded client-side (`COPY` from the notebook, or
`\copy` in psql).

`extract.py` is the standalone Python equivalent, used when the pipeline is run
from files rather than from the database: dumps all five `public` tables plus
`raw_sales.csv` to `data/staging/` (`ETL_STAGING_DIR`, `RAW_SALES_CSV`), with
its own pre-flight checks — required columns present, no duplicate `sale_id`.

---

## 5. Step 3 — `transform.sql`: Issue by Issue

`etl.transform()` drops and rebuilds all of `transformed`, and **raises
exceptions rather than emitting bad data**. It also emits `NOTICE`s that the
notebook prints back — that is the run log.

### Issue 3 — `dim_date` month names wrong (667 rows)

`RAISE NOTICE` the count of rows where `month_name` disagrees with
`to_char(full_date,'Month')`, then rebuild the date attributes from
`full_date`: `day_of_week`, trimmed `month_name`, `quarter`, and
`is_weekend` (ISO dow 6 or 7). Gate: every `month_name` must equal its month
number, else `EXCEPTION`.

### Issues 2, 5, 9 — `dim_product` priced and classified

- `RAISE NOTICE` the source count of `unit_cost > list_price` (313).
- `base` — `btrim()` the name, category, subcategory.
- `cat` — `LEFT JOIN etl.product_category_map` on the trimmed name →
  `product_group`.
- `priced` — `LEFT JOIN LATERAL` on `etl.pricing_rules`, most specific
  `name_pattern` first (`ORDER BY length(name_pattern) DESC, rule_id LIMIT 1`),
  carrying `pricing_rule_id` for traceability.
- Adds computed columns `cost_gt_price`, `margin_pct`, `pricing_rule_id`.
- **Three gates:** no product without a `product_group`, none without a
  pricing rule, none with `cost_gt_price`.

### Issue 6 — duplicate customers (2,000 keys → fewer people)

- `customer_ranked`: normalise (trimmed name, lowercased email, `NULLIF('')`),
  count orders per customer, and score `completeness` = how many of
  name/city/country/segment are present.
- Survivor per group via `first_value() OVER (PARTITION BY coalesce(email || '|' || name_norm, '#' || customer_key) ORDER BY n_orders DESC, completeness DESC, customer_key)` — duplicate = **same email AND same name**; a NULL email or name can never merge anyone.
- `customer_dedup_map` (loser → survivor), `customer_duplicate_pairs`
  (side-by-side comparison of every same-email pair with `same_city`,
  `same_segment`, `merged` flags), `customer_review` (**same email, different
  names → deliberately NOT merged**), and `dim_customer` = survivors only.
- `fact_sales.customer_key` is rewritten to the survivor key, so revenue follows
  the person.
- Gate: no remaining `(email, lower(name))` duplicate in `dim_customer`.

### Issues 1, 2, 7 — `fact_sales`

- `qrule` resolves `quantity_basis`/`units_per_pack` per product via
  `quantity_rules`.
- Selects the fact rows with: `customer_key` → survivor, `category` from
  `raw_sales` when loaded (authoritative original) else the staging column,
  `category_matches_product` (Issue 8 flag), `quantity_basis`, `units_sold`,
  `qty_at_max`, `revenue_expected`, and `revenue_mismatch` (`> 0.05` deviation).

### The gates (all `RAISE EXCEPTION`)

1. fact row count unchanged — a lost row means a bad join or quantity rule.
2. no duplicate `sale_id`.
3. no sales row without a quantity rule.
4. no orphan `date_key` / `product_key` / `customer_key` / `store_key`.
5. no duplicate customers.
6. **category distribution still 42 / 26 / 20 / 12 %** — Option A is only
   Option A if the four original categories survive the journey.

Then two `NOTICE`s become the run report:

```
Issue 3: source month_name mismatches = 667
Issue 5: source products with unit_cost > list_price = 313
Issue 7: stored revenue differs from the standard formula on 99.91 percent of rows
Issue 8: sale category equals product category on 27.5 percent of rows
```

`customer_ranked` is dropped at the end — it is scaffolding, not output.

---

## 6. Step 4 — `load.sql`: Publish `clean` With Constraints

`etl.load()` refuses to run without `transformed.fact_sales`, then rebuilds
`clean` as a **constrained, self-documenting star schema**:

| Table | Constraints added |
|---|---|
| `clean.dim_date` | PK `date_key`, `CHECK` that `month_name` position = month number (Issue 3) |
| `clean.dim_product` | PK `product_key`, `product_group NOT NULL`, `CHECK (list_price >= unit_cost)` (Issue 5) |
| `clean.dim_customer` / `dim_store` | PK |
| `clean.fact_sales` | PK `sale_id`, `CHECK (0 <= discount_pct < 1)` (Issue 4), FKs to all four dimensions |
| `clean.customer_dedup_map` / `customer_review` / `customer_duplicate_pairs` | the Issue 6 audit trail, published |
| `clean.v_fact_sales` | view joining the fact to the product, exposing `product_category`, `product_group`, and `net_revenue = revenue_expected` |

Business definitions are stored **in the database** as column comments, so they
travel with the data: `revenue` = "Source revenue, kept for audit only. Not
reliable: see `revenue_mismatch`"; `revenue_expected` = "Official net revenue";
`units_sold` = "Quantity in single units".

`pipeline.sql` then adds the one-liner `etl.run_pipeline()` =
`transform()` + `load()`.

---

## 7. Running It — Notebook Cells 1–7

```
cell 1  imports + get_engine() + paths (SQL_DIR, DATA_DIR) + run_file()/query() helpers
cell 2  ## Step 2: reset public from the CSVs            (guarded by CONFIRM_RESET)
cell 3  the DROP / schema.sql / COPY block
cell 5  ## Step 3: install the rules and the three stage functions
cell 7  ## Step 4: run extract -> transform -> load
        SELECT etl.extract() → COPY raw_sales → SELECT etl.transform() → SELECT etl.load()
        then prints every NOTICE containing "Issue"
```

Cell 7 is where the four `Issue N` lines above come from — the pipeline's own
self-report, captured through `conn.notices` so `RAISE NOTICE` output is not
lost in the noise.

---

## 8. Price Scraping — Getting Real Prices Instead of Invented Ones

The pipeline's `pricing_rules` are a placeholder (median cost × 1.60). Real
prices had to come from a marketplace. Both scrapers read `products.txt`
(399–400 lines, one `"Brand Base Name"` per line, written by notebook cells 30
and 33) and use the **eBay Browse API** with OAuth client-credentials, a cached
token (`expires_in - 60`), `X-EBAY-C-MARKETPLACE-ID: EBAY_US`, and only
`urllib` + `csv` + `statistics` — no SDK.

```bash
export EBAY_CLIENT_ID=... EBAY_CLIENT_SECRET=... EBAY_ENV=production
python scrape.py 10            # test on the first 10 names
```

### `scrape.py` — v1, superseded

1. Search each full `"Brand Product"` name; keep listings whose title contains
   **≥ 60 %** of the name's words (`MATCH = 0.6`); price = **median**, needs
   `MIN_LISTINGS = 3`.
2. Re-search every name that failed **without** the brand.
3. Recover brands by regex-scanning the surviving titles against a 104-brand
   list; assign each still-unpriced row a **free** brand that has a price,
   preferring the row's own brand.
4. `assert` all output names unique → `final_prices.csv`
   (`old_name, product_name, price`).

**Why it was dropped:** it guessed brands from title text with a hand-written
list. The notebook shows the result — `scraped_prices.csv` loaded into
`public.scraped_prices` came back with **368 of 400 prices as NaN**, because the
brands in the names were invented and no such listing existed.

### `scrapedatabrand.py` — v2, the one that worked

The insight: **don't guess brands — ask eBay.** For each brand-less base name:

1. `fieldgroups=ASPECT_REFINEMENTS` on a 1-result search, then read eBay's own
   **Brand** aspect distribution and `dominantCategoryId`. Generic values
   (`unbranded`, `does not apply`, `n/a`, …) are dropped; the top
   `MAX_BRANDS = 15` by `matchCount` are kept.
2. Per brand, re-search with
   `aspect_filter=categoryId:<cat>,Brand:<brand>` (the `|` in brand names is
   escaped for the filter syntax), `limit=100`, filter
   `priceCurrency:USD,price:[5..5000],conditionIds:{1000}` — USD, new only.
3. Listing hygiene: title must cover **≥ 60 %** of the base-name words, and
   must **not** match
   `SKIP = case|cover|replacement|parts|broken|repair|manual|skin|strap|protector|sticker`
   — accessories and spare parts are the single biggest source of fake price
   matches. A brand needs `MIN_PER_BRAND = 2` survivors.
4. Record **median**, plus `min`/`max` and `n_used`. 4 threads, 0.2 s politeness
   sleep, errors logged per search instead of aborting the run.
5. Brand prefix stripping uses `POOL` (40 brands) so `"Sony 27" Monitor 144Hz"`
   → `27" Monitor 144Hz`.

Output `brand_prices.csv` → `public.brand_data`:
**529 rows, 42 base names, 387 distinct real brands** (Silpat, LÉKUÉ, Thermos,
MOVA, Tefal, Kingston, …), each with `ebay_matches`, `n_used`, `price`, `low`,
`high`. Loaded by notebook cell 34; cells 37–38 normalise non-brands
(`''`, `n/a`, `none`, `unknown`, `not specified`, `kitchen`, anything containing
`specified`) to `Non Brand`.

Both scripts support `python <script> N` to limit the run for testing, and both
fail fast on bad credentials by calling `token()` before any work starts.

---

## 9. Step 5 — The Pricing Repair (notebook cells 8–70)

This is the manual, one-off layer on top of the pipeline. Summary here, full
write-up in [`PricingIssueFix.md`](./PricingIssueFix.md).

| Cells | Action |
|---|---|
| 8–17 | Rebuild `dim_product.category` from `clean.dim_product.product_group` (drop → re-add → `UPDATE ... FROM`), then sync `fact_sales.category` |
| 19–25 | Give each row a unique name: `ROW_NUMBER() OVER (PARTITION BY product_name ORDER BY product_key)` against a 38-brand array → 42 names become 400 |
| 26–33 | Export `products.txt`; load `scraped_prices.csv` (the failed v1 attempt, kept as evidence) |
| 34–39 | Load `brand_prices.csv` → `brand_data`; normalise non-brands; cell 39 shows the median-price brand per product as a sanity view |
| 40–49 | Assign real brands + real prices: exact name match first (32 rows), then fill each base name from unclaimed brands ordered by `ebay_matches` (276 rows), `assert` 0 duplicate names, stage into `dim_product_sync`, then `UPDATE dim_product SET product_name, list_price` |
| 50–58 | Create `ref_cost_benchmark` (category × subcategory cost ratio bands), back up `unit_cost_original`, then `unit_cost = ROUND(list_price * (ratio_low + ratio_high) / 2, 2)` — reverse-margin derivation; drop the backup column again |
| 59–62 | Verify 0 products with `unit_cost >= list_price`, compare avg old vs new cost per band, drop `unit_cost_original` |
| 63–70 | Rename `list_price → retail_price` and `fact_sales.unit_price → retail_price`; propagate: `fact_sales.retail_price = dim_product.retail_price` and `revenue = ROUND(retail_price * (1 - discount_pct) * quantity, 2)` |

Result against the live database: **0** loss-making products (was 313),
**0** revenue mismatches (was 99.91 % of rows), 400 unique product names,
margins 17 / 23 / 29 / 31.5 / 38.5 / 46 % — one per category × subcategory band.

---

## 10. File Inventory

| File | Role |
|---|---|
| `main_pipeline.ipynb` | The driver. 71 cells: setup → reset → rules → stages → pricing repair |
| `rules.sql` | `etl` schema: category map, quantity rules, pricing rules, decision log |
| `extract.sql` | `etl.extract()` + `etl.validate_raw_sales()` |
| `transform.sql` | `etl.transform()` — the bulk of the logic, 8 gates |
| `load.sql` | `etl.load()` — `clean` schema, PKs/FKs/CHECKs, view, comments |
| `pipeline.sql` | `etl.run_pipeline()` convenience wrapper |
| `extract.py` | Standalone file-based extract (dumps to `data/staging/`) |
| `connectdb.py` | Engine factory for the notebook |
| `secretsget.py` | Docker `/run/secrets` → env → local file secret resolution |
| `scrape.py` | eBay scraper v1 — full-name search, brand recovery by regex (superseded) |
| `scrapedatabrand.py` | eBay scraper v2 — Brand aspect refinement, per-brand median prices (kept) |
| `products.txt` | Input list for both scrapers: one `"Brand Base Name"` per line |
| `requirements.txt` | Pinned venv freeze (Python 3.14) |
| `__pycache__/` | Stale build artefacts — `connectdb`, `scrape` |

---

## 11. Known Gaps / Next Steps

1. **92 products still carry the source floor price** (`5.00`) because their
   base name ran out of distinct brands. Raise `MAX_BRANDS`, or allow a brand
   to be reused across products.
2. **42 product names still say `Not Specified`** — cell 38 cleaned the SQL
   table, but cell 43 rebuilt assignments from the stale in-memory DataFrame
   loaded at cell 34. Re-run cells 43–48 after re-reading `brand_data`.
3. **`etl.pricing_rules` is still the placeholder** (median cost × 1.60). Now
   that real eBay prices exist, the rules should be seeded from
   `brand_data.price` so a fresh pipeline run produces good prices without the
   manual repair.
4. **Scratch tables left in `public`**: `scraped_prices`, `brand_data`,
   `dim_product_sync`. Move to a `scratch`/`staging` schema or drop them.
5. **`main_pipeline.ipynb` has saved outputs and a `CONFIRM_RESET = True`**
   default — re-running from the top destroys the pricing repair (step 9).
6. `extract.py` and the notebook do the same job two different ways; pick one as
   canonical.
7. eBay prices are a single marketplace (US), new-condition only, median of
   live listings — no shipping, no regional variance. `brand_data.low/high`
   should be used as sanity bands in any downstream margin report.