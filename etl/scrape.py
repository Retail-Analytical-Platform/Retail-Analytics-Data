"""
scrape.py - price every product name on eBay. Names with no price are searched again WITHOUT the
brand; the row is then renamed to a brand that really exists for that product (all names unique).

  export EBAY_CLIENT_ID=... EBAY_CLIENT_SECRET=... EBAY_ENV=production
  python scrape.py [N]        # N = only the first N names (test run); reads products.txt: one "Brand Product" name per line
Output: final_prices.csv  (old_name, product_name, price)
"""
import base64, csv, json, os, re, statistics, sys, time
from concurrent.futures import ThreadPoolExecutor
import urllib.parse, urllib.request

ENV = os.environ.get("EBAY_ENV", "production")
HOST = {"sandbox": "https://api.sandbox.ebay.com", "production": "https://api.ebay.com"}[ENV]
MIN_LISTINGS, MATCH = 3, 0.6      # listings needed for a price / share of name words a title must contain
BRANDS = ("Sony,Samsung,LG,Philips,Apple,Xiaomi,Bose,JBL,Anker,Logitech,Dell,ASUS,Lenovo,Huawei,Panasonic,"
          "Sharp,Toshiba,Hisense,TCL,Dyson,Bosch,Siemens,Whirlpool,Electrolux,Tefal,Cuisinart,OXO,Ikea,Belkin,"
          "Baseus,TP-Link,Netgear,Razer,Corsair,Garmin,Sennheiser,Haier,Midea,Ninja,Shark,Kindle,Kobo,Onyx Boox,"
          "Silpat,Amazon Basics,Roborock,iRobot,Eufy,Totally Bamboo,Viofo,Nextbase,Vantrue,Keychron,Pyrex,"
          "Rubbermaid,Govee,GE,Bissell,Black+Decker,Aqara,Etekcity,Ozeri,Rain Design,Nulaxy,Satechi,Microsoft,"
          "SteelSeries,Vitruvi,Muji,T-fal,Calphalon,Hario,Chemex,Bodum,Wyze,Meross,Tempur-Pedic,Corelle,Gibson,"
          "Simplehuman,Espro,Victorinox,Henckels,Instant Pot,Crock-Pot,GoPro,DJI,Insta360,Lodge,Tramontina,"
          "Brooklinen,Utopia,InterDesign,Levoit,SanDisk,Crucial,WD,Oral-B,BenQ,Amazon,Google,HP,Acer,Fitbit").split(",")

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

def fetch(query, limit=50):
    """[(title, price_usd)] for one search."""
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
    """Listings whose title contains enough of the name's words."""
    w = words(name)
    return [(t, p) for t, p in listings if len(w & words(t)) / len(w) >= MATCH]

def price_of(name, listings):
    ps = [p for _, p in matches(name, listings)]
    return round(statistics.median(ps), 2) if len(ps) >= MIN_LISTINGS else None

def brands_found(base, listings):
    """{brand: (n_listings, median_price)} for brands named in matching listing titles."""
    found = {}
    for title, p in matches(base, listings):
        low = title.lower()
        hits = [(m.start(), b) for b in BRANDS
                if (m := re.search(r"(?<![a-z0-9])" + re.escape(b.lower()) + r"(?![a-z0-9])", low))]
        if hits: found.setdefault(min(hits)[1], []).append(p)
    return {b: (len(ps), round(statistics.median(ps), 2)) for b, ps in found.items()}

def main():
    names = list(dict.fromkeys(l.strip() for l in open("products.txt", encoding="utf-8-sig") if l.strip()))
    if len(sys.argv) > 1: names = names[:int(sys.argv[1])]      # python scrape.py 10  -> test on 10 names
    brand, base = (lambda n: n.split(" ", 1)[0]), (lambda n: n.split(" ", 1)[1])
    token()                                                     # fail early if the keys are wrong

    with ThreadPoolExecutor(5) as ex:                           # 1) price each full name, 5 searches at a time
        price = dict(zip(names, ex.map(lambda n: price_of(n, fetch(n)), names)))
    missing = [n for n in names if price[n] is None]
    bases = sorted({base(n) for n in missing})                  # 2) search without brand
    with ThreadPoolExecutor(5) as ex:
        found = dict(zip(bases, ex.map(lambda b: brands_found(b, fetch(b, 200)), bases)))

    taken = {n for n in names if price[n] is not None}          # 3) give each missing row a free brand with a price
    out = {n: (n, price[n]) for n in taken}
    for n in sorted(missing, key=lambda n: (brand(n) not in found[base(n)], n)):    # own-brand rows go first
        options = sorted(found[base(n)].items(), key=lambda kv: (kv[0] != brand(n), -kv[1][0], kv[0]))
        out[n] = next(((f"{b} {base(n)}", v[1]) for b, v in options if f"{b} {base(n)}" not in taken), (n, None))
        taken.add(out[n][0])

    assert len({v[0] for v in out.values()}) == len(names), "duplicate names"
    with open("final_prices.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f); w.writerow(["old_name", "product_name", "price"])
        for n in names: w.writerow([n, *out[n]])
    print(sum(out[n][1] is not None for n in names), "of", len(names), "priced;",
          sum(out[n][0] != n for n in names), "renamed -> final_prices.csv")

if __name__ == "__main__":
    main()