"""
scrape_prices.py - estimate a market list price per product (name + category) and load it
into etl.pricing_rules.

  python scrape_prices.py scrape          # 1) scrape -> scraped_prices.csv  (REVIEW THIS FILE)
  python scrape_prices.py apply           # 2) load the reviewed CSV into etl.pricing_rules
  then in SQL:  SELECT etl.transform(); SELECT etl.load();

ALGORITHM (per product name):
  1. query   = product name; the category only chooses the price bounds / margin below
  2. fetch   = search page of ONE source (robots.txt respected, polite delay)
  3. extract = (title, price) pairs: schema.org JSON-LD first, CSS selectors as fallback
  4. filter  = keep a listing only if (a) its title shares >= TITLE_MATCH_MIN of the product-name
               tokens and (b) its price is inside the category's plausible price band
  5. robust  = drop outliers (more than 3 scaled MADs from the median), take the MEDIAN of what is left
  6. need    = at least MIN_SAMPLES listings, otherwise status = 'no_data' (nothing is written)
  7. cost    = price x (1 - assumed margin of the category). Retail sites show prices, not costs,
               so unit_cost is an ASSUMPTION and is labelled that way in the `source` column.
"""
import csv, datetime, json, re, statistics, sys, time, urllib.parse, urllib.robotparser
import requests
from bs4 import BeautifulSoup
from sqlalchemy import text

CONFIG = {
    "search_url": "https://YOUR-SHOP.example/search?q={query}",   # <-- EDIT: one source you may scrape
    "source_label": "your-shop.example",                          # <-- EDIT: written to pricing_rules.source
    "user_agent": "pricing-research-bot/1.0 (contact: you@example.com)",
    "delay_seconds": 3,
    "min_samples": 3,
    "title_match_min": 0.60,
    "price_bounds": {"Electronics": (15, 5000), "Home": (5, 1500)},   # sanity band per category
    "assumed_margin": {"Electronics": 0.25, "Home": 0.40},            # cost = price * (1 - margin)
    # Fallback when the page has no JSON-LD (set all three, else leave None):
    "css_item": None, "css_title": None, "css_price": None,           # e.g. "div.product", "h2", "span.price"
    "csv_path": "scraped_prices.csv",
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
    r = requests.get(url, headers={"User-Agent": CONFIG["user_agent"]}, timeout=20)
    r.raise_for_status()
    return r.text

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

def extract_listings(html):
    soup, out = BeautifulSoup(html, "html.parser"), []
    for tag in soup.find_all("script", type="application/ld+json"):
        try: _walk(json.loads(tag.string or ""), out)
        except ValueError: pass
    c = CONFIG
    if not out and c["css_item"] and c["css_title"] and c["css_price"]:
        for item in soup.select(c["css_item"]):
            t, p = item.select_one(c["css_title"]), item.select_one(c["css_price"])
            if t and p and parse_price(p.get_text()): out.append((t.get_text(" ", strip=True), parse_price(p.get_text())))
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
def scrape(engine):
    with engine.connect() as c:
        products = c.execute(text("SELECT product_name, category FROM etl.product_category_map ORDER BY 1")).fetchall()
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

def apply(engine):
    label = "SCRAPED %s %s; unit_cost ASSUMED margin" % (CONFIG["source_label"], datetime.date.today())
    done = 0
    with engine.begin() as c, open(CONFIG["csv_path"]) as f:
        for r in csv.DictReader(f):
            if r["status"] != "ok" or not r["list_price"]: continue
            res = c.execute(text("""UPDATE etl.pricing_rules
                                    SET list_price = :lp, unit_cost = :uc, source = :src
                                    WHERE category = :g AND name_pattern = :n"""),
                            {"lp": r["list_price"], "uc": r["unit_cost"], "src": label,
                             "g": r["product_group"], "n": r["product_name"]})
            done += res.rowcount
    print(f"{done} pricing rules updated; products without data keep their old placeholder price")

if __name__ == "__main__":
    from db import get_engine
    {"scrape": scrape, "apply": apply}[sys.argv[1]](get_engine())