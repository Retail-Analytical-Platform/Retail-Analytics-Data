# Load CSV into PostgreSQL (Docker Volume)

Continuation of [Docker.md](Docker.md). This tutorial loads the
[`data/`](/data/README.md) dataset (CSV) into the `retailspg` container, so it
can be used right away for SQL query practice.

> **Prerequisite**: the `retailspg` container must already be running (see
> [Docker.md § 2](Docker.md#2-jalankan-postgresql-di-container)). Check with
> `docker ps` — a container named `retailspg` should appear.

## Table of Contents

1. [Brief concept](#1-brief-concept)
2. [Create tables (schema)](#2-create-tables-schema)
3. [Copy CSV into the container](#3-copy-csv-into-the-container)
4. [Load CSV into tables](#4-load-csv-into-tables)
5. [Verification](#5-verification)
6. [Reload from scratch](#6-reload-from-scratch)

---

## 1. Brief concept

`psql` running **inside the container** cannot see files on our (host)
computer directly. So the flow has two steps:

1. **`docker cp`** — copy the file from the host into the container's
   filesystem.
2. **`COPY` / `\copy`** — a PostgreSQL command that reads that file and
   inserts its contents into a table.

As for "stored in the volume" — that happens automatically. The
`retailspg-data` volume is mounted to `/var/lib/postgresql/data`, which is the
path where PostgreSQL physically stores all its tables. As soon as data goes
in via `COPY`, it's automatically already in the volume — there's no separate
step for "saving to the volume."

## 2. Create tables (schema)

The tables must already exist before running `COPY`, with columns matching
the CSV. The schema is already prepared in [`data/schema.sql`](data/schema.sql)
— 4 dimension tables + 1 fact table, following the model in
[`data/README.md`](data/README.md#the-model).

```bash
# copy the schema file into the container
docker cp data/schema.sql retailspg:/schema.sql

# run it to create all the tables
docker exec retailspg psql -U postgres -f /schema.sql
```

## 3. Copy CSV into the container

```bash
docker cp data/dim_date.csv     retailspg:/dim_date.csv
docker cp data/dim_product.csv  retailspg:/dim_product.csv
docker cp data/dim_customer.csv retailspg:/dim_customer.csv
docker cp data/dim_store.csv    retailspg:/dim_store.csv
docker cp data/fact_sales.csv   retailspg:/fact_sales.csv
```

## 4. Load CSV into tables

Disclaimer: if a duplicate key error appears during copying, try refreshing
the SQL table view — that error occurs because the table already has data in
the database.

Order **matters**: dimension tables first, `fact_sales` last — because
`fact_sales` has foreign keys to all four dimensions (a sales row can't
reference a customer/product/store/date that doesn't exist yet).

```bash
docker exec retailspg psql -U postgres -c "\copy dim_date     FROM '/dim_date.csv'     WITH (FORMAT csv, HEADER true)"
docker exec retailspg psql -U postgres -c "\copy dim_product  FROM '/dim_product.csv'  WITH (FORMAT csv, HEADER true)"
docker exec retailspg psql -U postgres -c "\copy dim_customer FROM '/dim_customer.csv' WITH (FORMAT csv, HEADER true)"
docker exec retailspg psql -U postgres -c "\copy dim_store    FROM '/dim_store.csv'    WITH (FORMAT csv, HEADER true)"
docker exec retailspg psql -U postgres -c "\copy fact_sales   FROM '/fact_sales.csv'   WITH (FORMAT csv, HEADER true)"
```

Brief explanation:
- `\copy` — a client-side `psql` command (note the `\` in front) that reads
  the file and sends it to the server.
- `WITH (FORMAT csv, HEADER true)` — specifies the CSV format, and
  `HEADER true` so the first row (column names) is skipped rather than being
  inserted as data.

## 5. Verification

```bash
docker exec retailspg psql -U postgres -c "
  SELECT 'dim_date', count(*) FROM dim_date
  UNION ALL SELECT 'dim_product', count(*) FROM dim_product
  UNION ALL SELECT 'dim_customer', count(*) FROM dim_customer
  UNION ALL SELECT 'dim_store', count(*) FROM dim_store
  UNION ALL SELECT 'fact_sales', count(*) FROM fact_sales;"
```

Expected row counts (per [`data/README.md`](data/README.md)):

| Table | Row count |
|---|---|
| `dim_date` | 730 |
| `dim_product` | 400 |
| `dim_customer` | 2,000 |
| `dim_store` | 40 |
| `fact_sales` | 60,000 |

If the numbers match, the data is complete and consistent (foreign key
integrity has already been verified in
[`data/INTEGRITY.txt`](data/INTEGRITY.txt)).

## 6. Reload from scratch

`COPY` will fail if a table already has data in it (primary key conflict). To
reload starting from empty:

```bash
docker exec retailspg psql -U postgres -c "
  TRUNCATE fact_sales, dim_date, dim_product, dim_customer, dim_store CASCADE;"
```

Then repeat step 4. Or, if you want to start completely from zero (including
removing the volume), see
[Docker.md § 5](Docker.md#5-command-docker-sehari-hari) for `docker rm -f`,
then recreate the container.

---

Want this data to be online / accessible to the team without everyone running
Docker themselves? Continue to
[Supabase-Migration.md](Supabase-Migration.md).
