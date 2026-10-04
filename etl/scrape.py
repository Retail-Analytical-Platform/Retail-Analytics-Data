"""
scrape_prices.py - estimate a market list price per product (name + category) and load it
into etl.pricing_rules.

  python scrape_prices.py scrape          # 1) scrape -> scraped_prices.csv  (REVIEW THIS FILE)
  python scrape_prices.py template        # (alternative to 1) CSV with a search link per product, fill prices BY HAND
  python scrape_prices.py apply           # 2) load the reviewed CSV into etl.pricing_rules
  python scrape_prices.py enrich          # 3) add list_price / unit_cost / price_source columns to your products CSV
  then in SQL:  SELECT etl.transform(); SELECT etl.load();

ALGORITHM (per product name):
  1. query   = product name; the category only chooses the price bounds / margin below
  2. fetch   = search page of ONE source (robots.txt respected, polite delay)
  3. extract = (title, price) pairs: schema.org JSON-LD first, a regex you configure as fallback
  4. filter  = keep a listing only if (a) its title shares >= TITLE_MATCH_MIN of the product-name
               tokens and (b) its price is inside the category's plausible price band
  5. robust  = drop outliers (more than 3 scaled MADs from the median), take the MEDIAN of what is left
  6. need    = at least MIN_SAMPLES listings, otherwise status = 'no_data' (nothing is written)
  7. cost    = price x (1 - assumed margin of the category). Retail sites show prices, not costs,
               so unit_cost is an ASSUMPTION and is labelled that way in the `source` column.
"""
import csv, datetime, html, json, os, re, shutil, statistics, sys, time
import urllib.parse, urllib.request, urllib.robotparser
from sqlalchemy import text      # already installed for your notebook; nothing else to install

CONFIG = {
    "search_url": "https://www.tokopedia.com/search?st=&q=electronik&srp_component_id=02.01.00.00&srp_page_id=&srp_page_title=&navsource=",   # <-- EDIT: one source you may scrape
    "source_label": "self-scrape-tokped",                          # <-- EDIT: written to pricing_rules.source
    "user_agent": "pricing-research-bot/1.0 (contact: you@example.com)",
    "delay_seconds": 3,
    "min_samples": 3,
    "title_match_min": 0.60,
    "price_bounds": {"Electronics": (15, 5000), "Home": (5, 1500)},   # sanity band per category
    "assumed_margin": {"Electronics": 0.25, "Home": 0.40},            # cost = price * (1 - margin)
    # Fallback when the page has no JSON-LD: one regex with named groups (?P<title>...) and (?P<price>...)
    # example: r'<h2[^>]*>(?P<title>.*?)</h2>.*?class="price"[^>]*>(?P<price>[^<]+)<'
    "re_listing": None,
    "csv_path": "scraped_prices.csv",                             # output file (also read by `apply`)
    # YOUR product list. Leave products_csv = None to read etl.product_category_map instead.
    "products_csv": None,            # <-- e.g. "/home/joseph/Projects/Retail-Analytics-Data/data/products_to_price.csv"
    "name_column": "product_name",   # column holding the product name (= the search query)
    "category_column": "category",   # column holding the category (optional; see load_products)
}

# ---------------------------------------------------------------- fetching
_robots = {}
def allowed(url):
    root = "{0.scheme}://{0.netloc}".format(urllib.parse.urlparse(url))
    if root not in _robots:
        rp = urllib.robotparser.RobotFileParser(root + "/robots.txt")
        try: rp.read()
        except Exception: rp = None
        _robots[root] = rp
    rp = _robots[root]
    return True if rp is None else rp.can_fetch(CONFIG["user_agent"], url)

def fetch_html(url):
    """Swap this function for an official API client (eBay Browse, Google Shopping, ...) if you can."""
    if not allowed(url):
        raise PermissionError("blocked by robots.txt: " + url)
    req = urllib.request.Request(url, headers={"User-Agent": CONFIG["user_agent"]})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read().decode("utf-8", errors="replace")

# ---------------------------------------------------------------- parsing
def parse_price(value):
    if value is None: return None
    m = re.search(r"\d[\d,]*\.?\d*", str(value))
    return float(m.group().replace(",", "")) if m else None

def _walk(node, out):
    if isinstance(node, list):
        for x in node: _walk(x, out)
    elif isinstance(node, dict):
        if node.get("name") and "offers" in node:
            offers = node["offers"]; offers = offers if isinstance(offers, list) else [offers]
            for o in offers:
                price = parse_price(o.get("price", o.get("lowPrice"))) if isinstance(o, dict) else None
                if price: out.append((str(node["name"]), price))
        for v in node.values(): _walk(v, out)

def extract_listings(page):
    out = []
    for block in re.findall(r'<script[^>]*type=["\']application/ld\+json["\'][^>]*>(.*?)</script>',
                            page, flags=re.I | re.S):
        try: _walk(json.loads(block), out)
        except ValueError: pass
    if not out and CONFIG["re_listing"]:
        for m in re.finditer(CONFIG["re_listing"], page, flags=re.I | re.S):
            title = html.unescape(re.sub(r"<[^>]+>", " ", m.group("title"))).strip()
            price = parse_price(m.group("price"))
            if title and price: out.append((title, price))
    return out

# ---------------------------------------------------------------- filtering and pricing
def tokens(s): return set(re.findall(r"[a-z0-9]+", s.lower()))

def title_score(product_name, title):
    want = tokens(product_name)
    return len(want & tokens(title)) / len(want) if want else 0.0

def robust_median(prices):
    """Drop outliers with the median-absolute-deviation rule (works for small samples), then take the median."""
    med = statistics.median(prices)
    mad = statistics.median(abs(p - med) for p in prices)
    if mad > 0:
        prices = [p for p in prices if abs(p - med) <= 3 * 1.4826 * mad]
    return statistics.median(prices), len(prices)

def estimate(product_name, group, listings):
    lo, hi = CONFIG["price_bounds"][group]
    kept = [p for t, p in listings
            if title_score(product_name, t) >= CONFIG["title_match_min"] and lo <= p <= hi]
    if len(kept) < CONFIG["min_samples"]:
        return {"status": "no_data", "n_listings": len(listings), "n_used": len(kept)}
    price, n_used = robust_median(kept)
    if n_used < CONFIG["min_samples"]:
        return {"status": "no_data", "n_listings": len(listings), "n_used": n_used}
    price = round(price, 2)
    cost = round(price * (1 - CONFIG["assumed_margin"][group]), 2)
    return {"status": "ok", "n_listings": len(listings), "n_used": n_used, "list_price": price, "unit_cost": cost}

# ---------------------------------------------------------------- run
def load_products(engine):
    """Return [(product_name, product_group)], one row per distinct name.
    product_group must be a key of price_bounds (Electronics / Home). It comes from the CSV category
    when that value is a group; otherwise it is looked up by name in etl.product_category_map."""
    with engine.connect() as c:
        db_map = {n: g for n, g in c.execute(text("SELECT product_name, category FROM etl.product_category_map"))}
    if not CONFIG["products_csv"]:
        return sorted(db_map.items(), key=lambda x: x[0])
    out, seen = [], set()
    with open(CONFIG["products_csv"], newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for col in (CONFIG["name_column"],):
            if col not in reader.fieldnames:
                raise KeyError("column %r not in %s; columns are %s" % (col, CONFIG["products_csv"], reader.fieldnames))
        for r in reader:
            name = (r[CONFIG["name_column"]] or "").strip()
            if not name or name in seen: continue
            seen.add(name)
            cat = (r.get(CONFIG["category_column"]) or "").strip()
            group = cat if cat in CONFIG["price_bounds"] else db_map.get(name)
            if group is None:
                print("skipped (no product_group for it): %s" % name); continue
            out.append((name, group))
    return sorted(out)

def scrape(engine):
    products = load_products(engine)
    rows = []
    for name, group in products:
        url = CONFIG["search_url"].format(query=urllib.parse.quote_plus(name))
        try:
            res = estimate(name, group, extract_listings(fetch_html(url)))
        except Exception as e:
            res = {"status": "error: %s" % e, "n_listings": 0, "n_used": 0}
        rows.append({"product_name": name, "product_group": group, "source_url": url, **res})
        print(f"{name:35s} {res['status']:8s} {res.get('list_price', '')}")
        time.sleep(CONFIG["delay_seconds"])
    cols = ["product_name", "product_group", "status", "n_listings", "n_used", "list_price", "unit_cost", "source_url"]
    with open(CONFIG["csv_path"], "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols); w.writeheader(); w.writerows(rows)
    print("written", CONFIG["csv_path"], "- review it, then run: apply")

def template(engine):
    """Manual route: one row per product with a search link to open in your browser. Type list_price
    (unit_cost may stay blank: it is then calculated with the assumed margin) and keep status = manual."""
    products = load_products(engine)
    cols = ["product_name", "product_group", "status", "n_listings", "n_used", "list_price", "unit_cost", "source_url"]
    with open(CONFIG["csv_path"], "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols); w.writeheader()
        for name, group in products:
            w.writerow({"product_name": name, "product_group": group, "status": "manual",
                        "source_url": CONFIG["search_url"].format(query=urllib.parse.quote_plus(name))})
    print("written", CONFIG["csv_path"], "- fill list_price, then run: apply")

def _price_row(r):
    """(list_price, unit_cost, label) for a reviewed row of the scraped/template CSV, or None to skip it."""
    if r["status"] not in ("ok", "manual") or not (r["list_price"] or "").strip(): return None
    price = round(float(r["list_price"]), 2)
    given = (r["unit_cost"] or "").strip()
    cost = round(float(given), 2) if given else round(price * (1 - CONFIG["assumed_margin"][r["product_group"]]), 2)
    label = "%s %s %s; unit_cost %s" % ("SCRAPED" if r["status"] == "ok" else "MANUAL", CONFIG["source_label"],
                                         datetime.date.today(), "as given" if given else "ASSUMED margin")
    return price, cost, label

def apply(engine):
    done = 0
    with engine.begin() as c, open(CONFIG["csv_path"], newline="", encoding="utf-8-sig") as f:
        for r in csv.DictReader(f):
            pr = _price_row(r)
            if not pr: continue
            res = c.execute(text("""UPDATE etl.pricing_rules
                                    SET list_price = :lp, unit_cost = :uc, source = :src
                                    WHERE category = :g AND name_pattern = :n"""),
                            {"lp": pr[0], "uc": pr[1], "src": pr[2], "g": r["product_group"], "n": r["product_name"]})
            done += res.rowcount
    print(f"{done} pricing rules updated; products without a price keep their old placeholder")

def enrich():
    """Add list_price, unit_cost and price_source columns to CONFIG['products_csv'] (matched by product name).
    The original file is copied once to <file>.bak. Needs no database connection."""
    src = CONFIG["products_csv"]
    if not src: sys.exit("Set CONFIG['products_csv'] first.")
    prices = {}
    with open(CONFIG["csv_path"], newline="", encoding="utf-8-sig") as f:
        for r in csv.DictReader(f):
            pr = _price_row(r)
            if pr: prices[r["product_name"].strip()] = pr
    raw = open(src, "rb").read()
    bom, eol = raw.startswith(b"\xef\xbb\xbf"), ("\r\n" if b"\r\n" in raw else "\n")
    if not os.path.exists(src + ".bak"): shutil.copyfile(src, src + ".bak")
    with open(src, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f); fields, rows = list(reader.fieldnames), list(reader)
    if CONFIG["name_column"] not in fields:
        sys.exit("column %r not in %s; columns are %s" % (CONFIG["name_column"], src, fields))
    new_cols = ["list_price", "unit_cost", "price_source"]
    fields += [c for c in new_cols if c not in fields]
    filled = 0
    for row in rows:
        pr = prices.get((row[CONFIG["name_column"]] or "").strip())
        row["list_price"], row["unit_cost"], row["price_source"] = pr if pr else ("", "", "")
        filled += bool(pr)
    with open(src, "w", newline="", encoding="utf-8-sig" if bom else "utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields, lineterminator=eol); w.writeheader(); w.writerows(rows)
    print(f"{src}: {filled} of {len(rows)} rows now have a price ({len(prices)} distinct products). Backup: {src}.bak")

if __name__ == "__main__":
    commands = {"scrape": scrape, "template": template, "apply": apply, "enrich": enrich}
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        sys.exit("Usage: python %s <command>\n  scrape    fetch prices from CONFIG['search_url']\n"
                 "  template  write a CSV to fill prices by hand\n  apply     load the reviewed CSV into etl.pricing_rules\n"
                 "  enrich    add price columns to your products CSV" % sys.argv[0])
    if sys.argv[1] == "enrich":
        enrich()
    else:
        try: from connectdb import get_engine      # your project
        except ImportError: from connectdb import get_engine
        commands[sys.argv[1]](get_engine())