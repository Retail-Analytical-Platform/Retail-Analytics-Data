#!/bin/sh
set -eu

log() { printf 'etl: %s\n' "$*"; }
die() { printf 'etl: ERROR: %s\n' "$*" >&2; exit 1; }

url=$(cat /run/secrets/database_url 2>/dev/null || true)
url=${url:-${DATABASE_URL:-}}
[ -n "$url" ] || die 'no database URL in /run/secrets/database_url or DATABASE_URL'

psql_db() {
    psql -w -v ON_ERROR_STOP=1 -d "$url" "$@"
}

attempt=0
until psql_db -Atqc 'SELECT 1' >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 30 ] || die 'database not reachable after 60 seconds'
    [ "$attempt" -eq 1 ] && log 'waiting for database...'
    sleep 2
done
log 'connected'

fact_exists=$(psql_db -Atqc "SELECT to_regclass('public.fact_sales') IS NOT NULL")
if [ "$fact_exists" != 't' ]; then
    log 'initializing public schema from CSV files'
    psql_db -f /app/data/schema.sql
    for table in dim_date dim_product dim_customer dim_store fact_sales; do
        log "load public.$table"
        psql_db -c "\\copy public.$table FROM '/app/data/$table.csv' WITH (FORMAT csv, HEADER true)"
    done
fi

for file in rules extract transform load pipeline; do
    [ -f "/app/etl/$file.sql" ] || die "/app/etl/$file.sql not found"
    log "install etl/$file.sql"
    psql_db -f "/app/etl/$file.sql"
done

if [ "$(psql_db -Atqc 'SELECT count(*) FROM public.brand_data')" = '0' ]; then
    log 'load public.brand_data'
    psql_db -c "\\copy public.brand_data FROM '/app/data/brand_prices.csv' WITH (FORMAT csv, HEADER true)"
    psql_db -c "UPDATE public.brand_data SET brand = 'Non Brand' WHERE brand IS NULL OR lower(trim(brand)) IN ('', 'n/a', 'na', 'none', 'unknown', 'not specified', 'kitchen') OR lower(brand) LIKE '%specified%'"
fi

log 'extract'
psql_db -c 'SELECT etl.extract();'

if [ -f /app/data/raw/raw_sales.csv ]; then
    log 'raw_sales <- /app/data/raw/raw_sales.csv'
    psql_db -c "\\copy staging.raw_sales (sale_id, category) FROM '/app/data/raw/raw_sales.csv' WITH (FORMAT csv, HEADER true)"
elif [ -f /app/data/fact_sales.csv ]; then
    log 'raw_sales <- /app/data/fact_sales.csv'
    psql_db -c "\\copy staging.raw_sales (sale_id, category) FROM PROGRAM 'tail -n +2 /app/data/fact_sales.csv | cut -d, -f1,11' WITH (FORMAT csv)"
else
    log 'raw_sales <- public.fact_sales'
    psql_db -c 'INSERT INTO staging.raw_sales (sale_id, category) SELECT sale_id, category FROM public.fact_sales;'
fi

log 'pipeline'
psql_db -c 'SELECT etl.run_pipeline();'
rows=$(psql_db -Atqc 'SELECT count(*) FROM clean.fact_sales')
[ "$rows" = '60000' ] || die "clean.fact_sales contains $rows rows; expected 60000"
log "clean.fact_sales rows: $rows"
log 'pipeline finished'
