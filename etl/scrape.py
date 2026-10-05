"""
scrape.py - get a market price for each product name via the eBay Browse API.

Setup (once):
  export EBAY_CLIENT_ID="your App ID (Client ID)"
  export EBAY_CLIENT_SECRET="your Cert ID (Client Secret)"
  export EBAY_ENV="sandbox"          # or "production" (use the matching keyset!)

Run:
  python scrape.py          # all products in products.txt
  python scrape.py 5        # only the first 5 (test first)

Output: scraped_prices.csv -> product_name, status, n_listings, n_used, price, source_url
Re-running resumes: 'ok' / 'no_data' rows are skipped, 'error' rows are retried.
"""
import base64, csv, json, os, re, statistics, sys, time
import urllib.error, urllib.parse, urllib.request

CONFIG = {
    "env": os.environ.get("EBAY_ENV", "sandbox"),
    "client_id": os.environ.get("EBAY_CLIENT_ID"),
    "client_secret": os.environ.get("EBAY_CLIENT_SECRET"),
    "marketplace": "EBAY_US",
    "currency": "USD",
    "limit": 50,                  # listings fetched per product (max 200)
    "delay_seconds": 0.5,
    "min_samples": 3,
    "title_match_min": 0.60,
    "min_price": 5,               # sanity band in USD
    "max_price": 5000,
    "products_file": "products.txt",   # .txt = one name per line; .csv = column name_column
    "name_column": "product_name",
    "csv_path": "scraped_prices.csv",
}
HOSTS = {"sandbox": "https://api.sandbox.ebay.com", "production": "https://api.ebay.com"}
SCOPE = "https://api.ebay.com/oauth/api_scope"
COLS = ["product_name", "status", "n_listings", "n_used", "price", "source_url"]

# ---------------------------------------------------------------- eBay API
_token = {"value": None, "expires": 0}

def _open(req):
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raise RuntimeError("HTTP %s %s" % (e.code, e.read().decode("utf-8", "replace")[:300]))

def get_token():
    """Application token (client-credentials grant). Cached until shortly before it expires."""
    if _token["value"] and time.time() < _token["expires"] - 60:
        return _token["value"]
    if not (CONFIG["client_id"] and CONFIG["client_secret"]):
        sys.exit("Set EBAY_CLIENT_ID and EBAY_CLIENT_SECRET first.")
    basic = base64.b64encode(("%s:%s" % (CONFIG["client_id"], CONFIG["client_secret"])).encode()).decode()
    req = urllib.request.Request(
        HOSTS[CONFIG["env"]] + "/identity/v1/oauth2/token",
        data=urllib.parse.urlencode({"grant_type": "client_credentials", "scope": SCOPE}).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded", "Authorization": "Basic " + basic})
    data = _open(req)
    _token.update(value=data["access_token"], expires=time.time() + int(data.get("expires_in", 7200)))
    return _token["value"]

def search_url(name):
    params = {"q": name, "limit": CONFIG["limit"],
              "filter": "priceCurrency:%s,price:[%s..%s]" % (CONFIG["currency"], CONFIG["min_price"], CONFIG["max_price"])}
    return HOSTS[CONFIG["env"]] + "/buy/browse/v1/item_summary/search?" + urllib.parse.urlencode(params)

def fetch_listings(name):
    """Return [(title, price)] for one product name."""
    req = urllib.request.Request(search_url(name), headers={
        "Authorization": "Bearer " + get_token(),
        "X-EBAY-C-MARKETPLACE-ID": CONFIG["marketplace"]})
    data = _open(req)
    out = []
    for item in data.get("itemSummaries", []):
        p = item.get("price") or {}
        if p.get("currency") == CONFIG["currency"] and p.get("value"):
            out.append((item.get("title", ""), float(p["value"])))
    return out

# ---------------------------------------------------------------- pricing
def tokens(s): return set(re.findall(r"[a-z0-9]+", s.lower()))

def title_score(product_name, title):
    want = tokens(product_name)
    return len(want & tokens(title)) / len(want) if want else 0.0

def robust_median(prices):
    med = statistics.median(prices)
    mad = statistics.median(abs(p - med) for p in prices)
    if mad > 0:
        prices = [p for p in prices if abs(p - med) <= 3 * 1.4826 * mad]
    return statistics.median(prices), len(prices)

def estimate(product_name, listings):
    kept = [p for t, p in listings if title_score(product_name, t) >= CONFIG["title_match_min"]]
    if len(kept) < CONFIG["min_samples"]:
        return {"status": "no_data", "n_listings": len(listings), "n_used": len(kept)}
    price, n_used = robust_median(kept)
    if n_used < CONFIG["min_samples"]:
        return {"status": "no_data", "n_listings": len(listings), "n_used": n_used}
    return {"status": "ok", "n_listings": len(listings), "n_used": n_used, "price": round(price, 2)}

# ---------------------------------------------------------------- run
def load_products(path):
    if path.lower().endswith(".csv"):
        with open(path, newline="", encoding="utf-8-sig") as f:
            reader = csv.DictReader(f)
            if CONFIG["name_column"] not in reader.fieldnames:
                sys.exit("column %r not in %s; columns are %s" % (CONFIG["name_column"], path, reader.fieldnames))
            names = [(r[CONFIG["name_column"]] or "").strip() for r in reader]
    else:
        with open(path, encoding="utf-8-sig") as f:
            names = [line.strip() for line in f]
    return list(dict.fromkeys(n for n in names if n))

def load_done():
    if not os.path.exists(CONFIG["csv_path"]): return {}
    with open(CONFIG["csv_path"], newline="", encoding="utf-8") as f:
        return {r["product_name"]: r for r in csv.DictReader(f) if r["status"] in ("ok", "no_data")}

def main():
    if CONFIG["env"] not in HOSTS:
        sys.exit("EBAY_ENV must be 'sandbox' or 'production'")
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else None
    products = load_products(CONFIG["products_file"])[:limit]
    done = load_done()
    todo = [n for n in products if n not in done]
    print(f"[{CONFIG['env']}] {len(products)} products, {len(done)} already done, {len(todo)} to fetch")
    get_token()                                   # fail early if the keys are wrong

    with open(CONFIG["csv_path"], "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=COLS, extrasaction="ignore")
        w.writeheader()
        for r in done.values(): w.writerow(r)
        for i, name in enumerate(todo, 1):
            try:
                res = estimate(name, fetch_listings(name))
            except Exception as e:
                res = {"status": "error: %s" % e, "n_listings": 0, "n_used": 0}
            w.writerow({"product_name": name, "source_url": search_url(name), **res})
            f.flush()
            print(f"[{i}/{len(todo)}] {name:45s} {res['status'][:40]:40s} {res.get('price', '')}")
            time.sleep(CONFIG["delay_seconds"])
    print("written", CONFIG["csv_path"])

if __name__ == "__main__":
    main()