#!/bin/sh
# Runs the SQL ETL pipeline against the database named by the
# /run/secrets/database_url Docker secret (or the DATABASE_URL env var).
# Invoked as the image CMD by docker/etl.Dockerfile.
set -eu

PSQL="psql -w -v ON_ERROR_STOP=1"

log() { printf 'etl: %s\n' "$*"; }
die() { printf 'etl: ERROR: %s\n' "$*" >&2; exit 1; }

# ---- 1. connection --------------------------------------------------------
url=$(cat /run/secrets/database_url 2>/dev/null || true)
url=${url:-${DATABASE_URL:-}}
[ -n "$url" ] || die "no connection string (secret /run/secrets/database_url or DATABASE_URL)"

i=0
until $PSQL -d "$url" -c 'SELECT 1' >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -ge 30 ] && die "database not reachable after 60s ($url)"
    [ "$i" -eq 1 ] && log "waiting for database..."
    sleep 2
done
log "connected"

# ---- 2. install the SQL objects ------------------------------------------
# rules.sql must run first: it seeds the lookup tables the stages read.
for f in rules extract transform load pipeline; do
    [ -f "etl/$f.sql" ] || die "etl/$f.sql not found in the image"
    log "install etl/$f.sql"
    $PSQL -d "$url" -f "etl/$f.sql"
done

# ---- 3. extract -----------------------------------------------------------
log "extract"
$PSQL -d "$url" -c 'SELECT etl.extract();'

if [ -f "${RAW_SALES_CSV:-}" ]; then
    log "raw_sales <- $RAW_SALES_CSV"
    $PSQL -d "$url" -c "\\copy staging.raw_sales (sale_id, category) FROM '$RAW_SALES_CSV' WITH (FORMAT csv, HEADER true)"
else
    log "raw_sales <- staging.fact_sales (no $RAW_SALES_CSV)"
    $PSQL -d "$url" -c 'INSERT INTO staging.raw_sales (sale_id, category) SELECT sale_id, category FROM staging.fact_sales;'
fi
$PSQL -d "$url" -c 'SELECT etl.validate_raw_sales();'

# ---- 4. transform + load --------------------------------------------------
log "transform"
$PSQL -d "$url" -c 'SELECT etl.transform();'
log "load"
$PSQL -d "$url" -c 'SELECT etl.load();'

log "pipeline finished"
