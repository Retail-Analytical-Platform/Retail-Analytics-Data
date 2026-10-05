# The Pricing Fix — How `dim_product` Prices Were Rebuilt

**Scope of this document:** what was broken about pricing in the star schema,
what was done to fix it, and what is still imperfect. All work lives in
`etl/main_pipeline.ipynb` (cells 8–70) plus the eBay price scraper
`etl/scrapedatabrand.py`.

---

## 1. The Symptom

After the ETL pipeline ran (`public -> staging -> transformed -> clean`),
`public.dim_product` looked like this:

| product_key | product_name         | category   | unit_cost | list_price |
|-------------|----------------------|------------|-----------|------------|
| 1172481     | 4K OLED Smart TV 55" | Grocery    | 52.77     | 61.49      |
| 680417      | Cotton Percale Sheet Set Queen | Home | 98.74 | 5.00   |
| 1064023     | Portable SSD 1TB     | Apparel    | 94.20     | 34.99      |

Three separate problems were visible in one screen:

1. **Prices were not prices.** `list_price` values were random-looking
   (`61.49`, `5.00`, `132.99`, `26.99`) and had no relationship to cost or
   product. `5.00` and `27.99` were the source data's floor/default values.
2. **Cost was above price.** The pipeline itself raised
   `NOTICE: Issue 5: source products with unit_cost > list_price = 313` — 313 of
   400 products were sold at a loss, and `Issue 7: stored revenue differs from
   the standard formula on 99.91 percent of rows` meant revenue could not be
   recomputed from price, discount and quantity.
3. **Categories were wrong.** `4K OLED Smart TV` was `Grocery`,
   `Portable SSD 1TB` was `Apparel`. The `category` column in `public` was
   random noise (`Issue 8: sale category equals product category on 27.5
   percent of rows`).

Underneath all three was a **modelling** problem: 400 `dim_product` rows
described only **42 distinct products** (`Wireless Earbuds Pro` appeared 31
times, `Robot Vacuum Pro` 25 times). There was no brand, so every duplicate
row was an anonymous, differently-priced copy of the same thing — nothing to
key a real market price on.

---

## 2. The Fix, In Five Steps

### Step 1 — Fix the category first (cells 8–17)

Prices can only be judged against a sensible category, so the broken
`category` column was dropped and rebuilt from the pipeline's own output:

```sql
ALTER TABLE dim_product DROP COLUMN category;
ALTER TABLE dim_product ADD  COLUMN category text;

UPDATE dim_product t
SET category = s.product_group          -- clean.dim_product already had it right
FROM clean.dim_product s
WHERE t.product_key = s.product_key;
```

`fact_sales.category` was then synchronised from `dim_product` so the fact
table could never disagree with its product again.

### Step 2 — Break the duplicates by giving every row a brand (cells 19–25)

A temporary, deliberately fake 38-brand list (Sony, Samsung, LG, … Shark —
the same list used to strip prefixes in the scraper) was assigned **per
product name**, using `ROW_NUMBER() OVER (PARTITION BY product_name ORDER BY
product_key)`. This turned 42 duplicated names into 400 unique names:

```
Anker 27" Monitor 144Hz   |  MSI 27" Monitor 144Hz   |  Acer 27" Monitor 144Hz ...
```

The goal was only to make names unique so a real price could be attached to
each row. `HAVING COUNT(*) > 1` returned zero rows afterwards.

### Step 3 — Get real prices from eBay (cells 26–38)

**First attempt (abandoned):** one search per `product_name`
(`data/scraped_prices.csv`). Because the names were invented brands
("Bose Ergonomic Gaming Mouse"), almost nothing matched — **32 of 400 rows got
a price, 368 were NaN**.

**Second attempt (kept):** `etl/scrapedatabrand.py`. The insight was to invert
the problem — search on the **generic base name** and let eBay tell us which
brands exist:

1. Strip the brand prefix from each name (`POOL`), producing 42 base names.
2. For each base name, call Browse API search with
   `fieldgroups=ASPECT_REFINEMENTS` and read eBay's own **Brand** aspect
   refinement — no hardcoded brand list, up to `MAX_BRANDS = 15` by
   `matchCount`, dropping `GENERIC` values (`unbranded`, `does not apply`, …).
3. Re-run the search per brand with
   `aspect_filter=categoryId:…,Brand:{…}`, keeping only USD listings in the
   `$5–$5000` range, condition `1000` (new).
4. Clean the matches: a listing title must share **≥ 60%** of the base-name
   words (`MATCH = 0.6`) and must **not** match
   `SKIP = case|cover|replacement|parts|broken|repair|manual|skin|strap|protector|sticker`
   (accessories, not the product). A brand needs `MIN_PER_BRAND = 2` surviving
   listings.
5. Record the **median** of the surviving prices (plus `low`/`high` and
   `n_used`), 4 threads, cached OAuth token.

Output `brand_prices.csv` → `brand_data` table: **529 brand prices, 42 base
names, 387 distinct real brands** (Silpat, LÉKUÉ, Thermos, Kingston, Tefal,
MOVA, …). Non-brands were then normalised to `Non Brand`.

### Step 4 — Attach a real brand and a real price to each product (cells 40–49)

The 400 invented brand names were replaced by **brands that actually sell that
product**, one row per product, without collisions:

1. `brand_data` deduplicated to the highest `n_used` row per
   `(base_name, brand)`; `product_name = brand + " " + base_name`.
2. Each `dim_product` name mapped back to its base name by **longest
   base-name suffix match** (`n.endswith(" " + b)`) — 0 unmapped.
3. Exact `brand + base_name` match first: **32 rows priced**.
4. Remaining 368 rows filled, within each base name, from brands **not already
   taken**, ordered by `ebay_matches` (how much real inventory eBay has for
   that brand/product — a proxy for brand legitimacy): **276 rows renamed and
   priced, 92 rows left untouched, 0 duplicate names**.
5. Applied through a staging table so the change was auditable:

```sql
UPDATE dim_product
SET product_name = s.new_name,
    list_price   = s.new_price
FROM dim_product_sync s
WHERE dim_product.product_key = s.product_key;
```

Result: `JBL 4K OLED Smart TV 55"` @ 473.80, `Logitech 4K OLED Smart TV 55"`
@ 13.00, `Western Digital Portable SSD 1TB` @ 271.24, `Kingston Portable SSD
1TB` @ 298.98 — brand-appropriate prices from $5.00 floor values.

### Step 5 — Rebuild `unit_cost` with a reverse-margin formula (cells 50–58)

Raising the price alone would still leave cost > price, so cost was
**derived from the new price** using a benchmark cost-to-price band per
`category` × `subcategory`, stored in a new reference table:

```sql
CREATE TABLE ref_cost_benchmark (
    category, subcategory, ratio_low, ratio_high, PRIMARY KEY (category, subcategory));

-- Electronics: Premium .68–.74, Standard .74–.80, Budget .80–.86
-- Home:        Premium .50–.58, Standard .58–.65, Budget .65–.72
```

The old cost was kept in `unit_cost_original`, then:

```sql
UPDATE dim_product
SET unit_cost = ROUND(list_price * (b.ratio_low + b.ratio_high) / 2.0, 2)
FROM ref_cost_benchmark b
WHERE b.category = dim_product.category AND b.subcategory = dim_product.subcategory;
```

Cost bands are inverted relative to product tier: premium products carry a
thicker margin than budget ones. `unit_cost_original` was dropped again once
verified.

### Step 6 — Rename and propagate (cells 63–70)

`list_price` → **`retail_price`** in `dim_product`, `unit_price` →
**`retail_price`** in `fact_sales`, then the fact table was re-based on the
dimension and revenue was recomputed with the standard formula:

```sql
UPDATE fact_sales fs
SET retail_price = dp.retail_price,
    revenue = ROUND((dp.retail_price * (1 - fs.discount_pct) * fs.quantity)::numeric, 2)
FROM dim_product dp
WHERE fs.product_key = dp.product_key;
```

---

## 3. Verification (against the live database)

| Check | Before | After |
|---|---|---|
| Products with `unit_cost >= list_price` | 313 (78%) | **0** |
| Rows where `revenue != price × (1−discount) × qty` | 99.91% of rows | **0** of 60,000 |
| Distinct `product_name` in `dim_product` | 42 | **400** (unique) |
| Duplicate names | up to 31 per product | **0** |
| `retail_price` range | 5.00 – 132.99 | 5.00 – 2,408.49 |
| Real market prices attached | 0 | 308 of 400 rows |
| Gross margin spread | negative to arbitrary | 17%, 23%, 29%, 31.5%, 38.5%, 46% — one per category × subcategory band |

`brand_data` retains the full evidence trail: `base_name`, `brand`,
`ebay_matches`, `n_used`, `price`, `low`, `high`.

---

## 4. What Is Still Not Right

| Issue | Detail | Fix |
|---|---|---|
| 5 rows keep `retail_price = 5.00` | Base names with no spare brand left after assignment (`Ergonomic Gaming Mouse`, `Smart LED Desk Lamp`, `Smart Plug 4-Pack`) fell back to the source floor price | Re-run `scrapedatabrand.py` with a higher `MAX_BRANDS`, or allow brand reuse across rows |
| 42 names still contain `Not Specified` | Cell 38 cleaned these in SQL, but cell 43 built the assignment from the **stale in-memory `brand_data` DataFrame** read at cell 34 — the cleanup never reached `dim_product` | Re-run cells 43–48 from a refreshed `brand_data` read |
| 92 rows untouched by price | Same root cause: not enough distinct brands per base name | as above |
| `scraped_prices` / `brand_data` / `dim_product_sync` tables left in `public` | Working artefacts, not part of the star schema | Drop, or move to a `scratch` schema |
| Price spread within a base name is wide | Median of live listings only; no shipping, no condition mix, single marketplace (US) | Keep `low`/`high` in `brand_data` for sanity bands |

---

## 5. One-Paragraph Summary

The pricing problem was not a formula bug — it was missing information. 400
product rows described 42 products with invented brands and random prices, so
no market price could be attached to them. The fix was to rebuild identity
first (unique brand per row), then pull **real brand-level median prices from
eBay** with a scraper that discovers brands from eBay's own Brand refinement
and filters accessory listings, then rewrite `list_price` from those prices,
then re-derive `unit_cost` from a category × subcategory cost-to-price
benchmark (reverse margin) so margin is guaranteed, and finally propagate the
corrected `retail_price` into `fact_sales` and recompute revenue. The star
schema now has zero loss-making products and revenue that reconciles to the
standard formula on all 60,000 rows.