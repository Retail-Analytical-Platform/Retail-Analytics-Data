"""
scrape.py - for each product (brand removed), ask eBay which brands sell it, then get each brand's price.
No fixed brand list: the brands come from eBay's own "Brand" refinement for that search.

  export EBAY_CLIENT_ID=... EBAY_CLIENT_SECRET=... EBAY_ENV=production
  python scrape.py [N]      # N = only the first N products (test run)
Input : products.txt (names with or without a brand prefix; the prefix is removed)
Output: brand_prices.csv  (base_name, brand, ebay_matches, n_used, price, low, high)
"""
import base64, csv, json, os, re, statistics, sys, time
import urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor

HOST = {"sandbox": "https://api.sandbox.ebay.com", "production": "https://api.ebay.com"}[os.environ.get("EBAY_ENV", "production")]
FILTER = "priceCurrency:USD,price:[5..5000],conditionIds:{1000}"     # USD, 5-5000, NEW condition
MAX_BRANDS = 15       # brands kept per product (most listings first); raise for a longer list
MIN_PER_BRAND = 2     # matching listings a brand needs before its price is recorded
MATCH = 0.6           # share of the product-name words a listing title must contain
POOL = ("Sony,Samsung,LG,Philips,Apple,Xiaomi,Bose,JBL,Anker,Logitech,Dell,ASUS,Lenovo,Huawei,Panasonic,Sharp,"
        "Toshiba,Hisense,TCL,Dyson,Bosch,Siemens,Whirlpool,Electrolux,Tefal,Cuisinart,OXO,Ikea,Belkin,Baseus,"
        "TP-Link,Netgear,Razer,Corsair,Garmin,Sennheiser,Haier,Midea,Ninja,Shark").split(",")   # prefixes on your names
GENERIC = {"unbranded", "generic", "does not apply", "unbranded/generic", "no brand", "n/a", "other"}
SKIP = re.compile(r"\b(case|cover|replacement|parts|broken|repair|manual|skin|strap|protector|sticker)\b", re.I)

_tok = {}
def token():
    if _tok.get("exp", 0) < time.time():
        auth = base64.b64encode(f"{os.environ['EBAY_CLIENT_ID']}:{os.environ['EBAY_CLIENT_SECRET']}".encode()).decode()
        req = urllib.request.Request(HOST + "/identity/v1/oauth2/token",
            data=urllib.parse.urlencode({"grant_type": "client_credentials", "scope": "https://api.ebay.com/oauth/api_scope"}).encode(),
            headers={"Authorization": "Basic " + auth, "Content-Type": "application/x-www-form-urlencoded"})
        d = json.load(urllib.request.urlopen(req, timeout=20))
        _tok.update(v=d["access_token"], exp=time.time() + d["expires_in"] - 60)
    return _tok["v"]

def get(params):
    """One Browse API search -> parsed JSON ({} on error)."""
    url = HOST + "/buy/browse/v1/item_summary/search?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token(), "X-EBAY-C-MARKETPLACE-ID": "EBAY_US"})
    try:
        data = json.load(urllib.request.urlopen(req, timeout=30))
    except Exception as e:
        print("error:", params.get("q"), e, flush=True); return {}
    time.sleep(0.2)
    return data

def words(s): return set(re.findall(r"[a-z0-9]+", s.lower()))

def brands_for(base):
    """[(base, brand, ebay_matches, n_used, median, low, high)] for every brand eBay lists for this product."""
    # 1) which brands exist for this search (eBay's own Brand refinement)
    ref = get({"q": base, "limit": 1, "filter": FILTER, "fieldgroups": "ASPECT_REFINEMENTS"}).get("refinement", {})
    cat, aspects = ref.get("dominantCategoryId"), ref.get("aspectDistributions", [])
    brand_aspect = next((a for a in aspects if a.get("localizedAspectName", "").lower() == "brand"), None)
    if not (cat and brand_aspect):
        print(f"{base:38s} no brand list returned (aspects: {[a.get('localizedAspectName') for a in aspects]})", flush=True)
        return []
    brands = sorted(((v.get("localizedAspectValue", ""), v.get("matchCount", 0))
                     for v in brand_aspect.get("aspectValueDistributions", [])
                     if v.get("localizedAspectValue", "").lower() not in GENERIC), key=lambda b: -b[1])[:MAX_BRANDS]
    # 2) the price of each brand: same search, filtered to that brand
    w, rows = words(base), []
    for brand, count in brands:
        data = get({"q": base, "limit": 100, "category_ids": cat, "filter": FILTER,
                    "aspect_filter": "categoryId:%s,Brand:{%s}" % (cat, brand.replace("|", "\\|"))})
        ps = [float(i["price"]["value"]) for i in data.get("itemSummaries", [])
              if i.get("price", {}).get("currency") == "USD"
              and len(w & words(i["title"])) / len(w) >= MATCH and not SKIP.search(i["title"])]
        if len(ps) >= MIN_PER_BRAND:
            rows.append((base, brand, count, len(ps), round(statistics.median(ps), 2), min(ps), max(ps)))
    print(f"{base:38s} {len(brands):2d} brands listed, {len(rows):2d} with a price", flush=True)
    return rows

def main():
    bases = []
    for line in open("products.txt", encoding="utf-8-sig"):
        name = line.strip()
        first, _, rest = name.partition(" ")
        name = rest if first in POOL and rest else name         # drop the brand prefix
        if name and name not in bases: bases.append(name)
    if len(sys.argv) > 1: bases = bases[:int(sys.argv[1])]
    print(len(bases), "products")
    token()                                                     # fail early if the keys are wrong
    with ThreadPoolExecutor(4) as ex:
        results = list(ex.map(brands_for, bases))
    with open("brand_prices.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f); w.writerow(["base_name", "brand", "ebay_matches", "n_used", "price", "low", "high"])
        for rows in results: w.writerows(rows)
    print(sum(map(len, results)), "brand prices -> brand_prices.csv")

if __name__ == "__main__":
    main()