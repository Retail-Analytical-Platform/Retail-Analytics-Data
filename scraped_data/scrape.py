#!/usr/bin/env python3
"""
Combined scraper - merges scrape.py and scrapedatabrand.py functionality
Outputs go to scraped_data directory (dynamically determined)
"""
import base64, csv, json, os, re, statistics, sys, time
from concurrent.futures import ThreadPoolExecutor
import urllib.parse, urllib.request
from pathlib import Path

# Determine directories dynamically
SCRIPT_DIR = Path(__file__).parent.resolve()
PROJECT_ROOT = SCRIPT_DIR.parent
ETL_DIR = PROJECT_ROOT / "etl"
DATA_DIR = PROJECT_ROOT / "data"
SCRAPED_DIR = SCRIPT_DIR

# Environment setup
ENV = os.environ.get("EBAY_ENV", "production")
HOST = {"sandbox": "https://api.sandbox.ebay.com", "production": "https://api.ebay.com"}[ENV]
FILTER = "priceCurrency:USD,price:[5..5000],conditionIds:{1000}"

# Configuration from scrape.py
MIN_LISTINGS, MATCH = 3, 0.6
BRANDS = ("Sony,Samsung,LG,Philips,Apple,Xiaomi,Bose,JBL,Anker,Logitech,Dell,ASUS,Lenovo,Huawei,Panasonic,"
          "Sharp,Toshiba,Hisense,TCL,Dyson,Bosch,Siemens,Whirlpool,Electrolux,Tefal,Cuisinart,OXO,Ikea,Belkin,"
          "Baseus,TP-Link,Netgear,Razer,Corsair,Garmin,Sennheiser,Haier,Midea,Ninja,Shark,Kindle,Kobo,Onyx Boox,"
          "Silpat,Amazon Basics,Roborock,iRobot,Eufy,Totally Bamboo,Viofo,Nextbase,Vantrue,Keychron,Pyrex,"
          "Rubbermaid,Govee,GE,Bissell,Black+Decker,Aqara,Etekcity,Ozeri,Rain Design,Nulaxy,Satechi,Microsoft,"
          "SteelSeries,Vitruvi,Muji,T-fal,Calphalon,Hario,Chemex,Bodum,Wyze,Meross,Tempur-Pedic,Corelle,Gibson,"
          "Simplehuman,Espro,Victorinox,Henckels,Instant Pot,Crock-Pot,GoPro,DJI,Insta360,Lodge,Tramontina,"
          "Brooklinen,Utopia,InterDesign,Levoit,SanDisk,Crucial,WD,Oral-B,BenQ,Amazon,Google,HP,Acer,Fitbit").split(",")

# Configuration from scrapedatabrand.py
MAX_BRANDS = 15
MIN_PER_BRAND = 2
POOL = ("Sony,Samsung,LG,Philips,Apple,Xiaomi,Bose,JBL,Anker,Logitech,Dell,ASUS,Lenovo,Huawei,Panasonic,Sharp,"
        "Toshiba,Hisense,TCL,Dyson,Bosch,Siemens,Whirlpool,Electrolux,Tefal,Cuisinart,OXO,Ikea,Belkin,Baseus,"
        "TP-Link,Netgear,Razer,Corsair,Garmin,Sennheiser,Haier,Midea,Ninja,Shark").split(",")
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
    url = HOST + "/buy/browse/v1/item_summary/search?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token(), "X-EBAY-C-MARKETPLACE-ID": "EBAY_US"})
    try:
        data = json.load(urllib.request.urlopen(req, timeout=30))
    except Exception as e:
        print("error:", params.get("q"), e, flush=True); return {}
    time.sleep(0.2)
    return data

def fetch(query, limit=50):
    url = HOST + "/buy/browse/v1/item_summary/search?" + urllib.parse.urlencode(
        {"q": query, "limit": limit, "filter": "priceCurrency:USD,price:[5..5000]"})
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token(), "X-EBAY-C-MARKETPLACE-ID": "EBAY_US"})
    try:
        items = json.load(urllib.request.urlopen(req, timeout=20)).get("itemSummaries", [])
    except Exception as e:
        print("error:", query, e); return []
    time.sleep(0.2)
    print(f"{query[:50]:50s} {len(items)} listings", flush=True)
    return [(i["title"], float(i["price"]["value"])) for i in items if i.get("price", {}).get("currency") == "USD"]

def words(s): return set(re.findall(r"[a-z0-9]+", s.lower()))

def matches(name, listings):
    w = words(name)
    return [(t, p) for t, p in listings if len(w & words(t)) / len(w) >= MATCH]

def price_of(name, listings):
    ps = [p for _, p in matches(name, listings)]
    return round(statistics.median(ps), 2) if len(ps) >= MIN_LISTINGS else None

def brands_found(base, listings):
    found = {}
    for title, p in matches(base, listings):
        low = title.lower()
        hits = [(m.start(), b) for b in BRANDS if (m := re.search(r"(?<![a-z0-9])" + re.escape(b.lower()) + r"(?![a-z0-9])", low))]
        if hits: found.setdefault(min(hits)[1], []).append(p)
    return {b: (len(ps), round(statistics.median(ps), 2)) for b, ps in found.items()}

def brands_for(base):
    ref = get({"q": base, "limit": 1, "filter": FILTER, "fieldgroups": "ASPECT_REFINEMENTS"}).get("refinement", {})
    cat, aspects = ref.get("dominantCategoryId"), ref.get("aspectDistributions", [])
    brand_aspect = next((a for a in aspects if a.get("localizedAspectName", "").lower() == "brand"), None)
    if not (cat and brand_aspect):
        print(f"{base:38s} no brand list returned", flush=True)
        return []
    brands = sorted(((v.get("localizedAspectValue", ""), v.get("matchCount", 0))
                     for v in brand_aspect.get("aspectValueDistributions", [])
                     if v.get("localizedAspectValue", "").lower() not in GENERIC), key=lambda b: -b[1])[:MAX_BRANDS]
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

def scrape_with_renaming(products_file=None):
    if products_file is None:
        for p in [ETL_DIR / "products.txt", SCRAPED_DIR / "products.txt", DATA_DIR / "products.txt"]:
            if p.exists():
                products_file = str(p)
                break
    with open(products_file, encoding="utf-8-sig") as f:
        names = list(dict.fromkeys(l.strip() for l in f if l.strip()))
    if len(sys.argv) > 1 and sys.argv[1].isdigit(): names = names[:int(sys.argv[1])]
    brand_fn, base_fn = (lambda n: n.split(" ", 1)[0]), (lambda n: n.split(" ", 1)[1])
    token()
    with ThreadPoolExecutor(5) as ex:
        price = dict(zip(names, ex.map(lambda n: price_of(n, fetch(n)), names)))
    missing = [n for n in names if price[n] is None]
    bases = sorted({base_fn(n) for n in missing})
    with ThreadPoolExecutor(5) as ex:
        found = dict(zip(bases, ex.map(lambda b: brands_found(b, fetch(b, 200)), bases)))
    taken = {n for n in names if price[n] is not None}
    out = {n: (n, price[n]) for n in taken}
    for n in sorted(missing, key=lambda n: (brand_fn(n) not in found[base_fn(n)], n)):
        options = sorted(found[base_fn(n)].items(), key=lambda kv: (kv[0] != brand_fn(n), -kv[1][0], kv[0]))
        out[n] = next(((f"{b} {base_fn(n)}", v[1]) for b, v in options if f"{b} {base_fn(n)}" not in taken), (n, None))
        taken.add(out[n][0])
    assert len({v[0] for v in out.values()}) == len(names), "duplicate names"
    output_file = SCRAPED_DIR / "final_prices.csv"
    with open(output_file, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f); w.writerow(["old_name", "product_name", "price"])
        for n in names: w.writerow([n, *out[n]])
    print(sum(out[n][1] is not None for n in names), "of", len(names), "priced;", sum(out[n][0] != n for n in names), "renamed ->", output_file)

def scrape_by_brand_aspects(products_file=None):
    if products_file is None:
        for p in [ETL_DIR / "products.txt", SCRAPED_DIR / "products.txt", DATA_DIR / "products.txt"]:
            if p.exists():
                products_file = str(p)
                break
    bases = []
    with open(products_file, encoding="utf-8-sig") as f:
        for line in f:
            name = line.strip()
            first, _, rest = name.partition(" ")
            name = rest if first in POOL and rest else name
            if name and name not in bases: bases.append(name)
    if len(sys.argv) > 1 and sys.argv[1].isdigit(): bases = bases[:int(sys.argv[1])]
    print(len(bases), "products")
    token()
    with ThreadPoolExecutor(4) as ex:
        results = list(ex.map(brands_for, bases))
    output_file = SCRAPED_DIR / "brand_prices.csv"
    with open(output_file, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f); w.writerow(["base_name", "brand", "ebay_matches", "n_used", "price", "low", "high"])
        for rows in results: w.writerows(rows)
    print(sum(map(len, results)), "brand prices ->", output_file)

def main():
    os.chdir(SCRAPED_DIR)
    print("Running scrape with renaming...")
    scrape_with_renaming()
    print("\nRunning scrape by brand aspects...")
    scrape_by_brand_aspects()

if __name__ == "__main__":
    main()