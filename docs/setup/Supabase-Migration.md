# Migrating Data to Supabase

Continuation of [Docker.md](Docker.md). Once
the dataset in `retailspg` (Docker) is complete and you want it available
online / shared with the team via Supabase, here's how.

> **Prerequisite**: data is already loaded into the `retailspg` container (run the
> ETL service, see [Docker.md § 3](Docker.md#3-run-the-etl-pipeline)), or at minimum
> `data/schema.sql` and the CSVs in `data/` already exist.

## Table of Contents

1. [Brief concept](#1-brief-concept)
2. [Create a Supabase project & get credentials](#2-create-a-supabase-project--get-credentials)
3. [Test the connection](#3-test-the-connection)
4. [Move the data](#4-move-the-data)
5. [Verify](#5-verify)
6. [Things to watch out for](#6-things-to-watch-out-for)

---

## 1. Brief concept

Supabase is Postgres too — they host a PostgreSQL instance in the cloud, plus
other features (Auth, Storage, Studio UI) on top. So "connecting Docker to
Supabase" isn't actually a Docker feature — you just **grab the connection
string from Supabase, then use a regular Postgres tool to move the data**
from the container into that database. Docker is just the data source, not
part of the connection process.

## 2. Create a Supabase project & get credentials

1. Sign up at [supabase.com](https://supabase.com) → **New Project**.
2. Pick a region, then set the **database password** — write it down
   carefully, Supabase won't show it again after this.
3. Open **Project Settings → Database**. There are two connection modes:

   | Mode | Port | Used for |
   |---|---|---|
   | **Direct connection** | `5432` | Schema migration, bulk data loads — this is what's used in this tutorial |
   | **Connection pooler (pgbouncer)** | `6543` | Used by applications at runtime (many short-lived connections) |

   The connection string looks like:
   ```
   postgresql://postgres:@db.<project-ref>.supabase.co:5432/postgres
   ```

## 3. Test the connection

```bash
psql "postgresql://postgres:@db.<project-ref>.supabase.co:5432/postgres"
```

If it connects successfully, the connection to Supabase is set up — no
VPN/firewall setup needed for a personal project.

## 4. Move the data

Two options, pick one:

### Option A — Replay schema.sql + CSV (recommended for this case)

`\copy` in `psql` runs on the **client** side, so it can read the CSV
directly from our own disk — just point it at
the Supabase connection string:

```bash
psql "postgresql://postgres:@db.<ref>.supabase.co:5432/postgres" -f data/schema.sql

psql "postgresql://postgres:@db.<ref>.supabase.co:5432/postgres" \
  -c "\copy dim_date FROM 'data/dim_date.csv' WITH (FORMAT csv, HEADER true)"
# repeat for dim_product, dim_customer, dim_store, then fact_sales last
```

Table order matters: dimensions first (`dim_date`, `dim_product`,
`dim_customer`, `dim_store`), `fact_sales` last (foreign keys).

### Option B — Dump from the container, restore into Supabase

Used when the `retailspg` container's state has diverged from the original
CSVs (e.g. manual changes have already been made) and it's that state you
want to move:

```bash
docker exec retailspg pg_dump -U postgres --no-owner --no-privileges postgres > dump.sql
psql "postgresql://postgres:@db.<ref>.supabase.co:5432/postgres" -f dump.sql
```

`--no-owner --no-privileges` matters — the `postgres` role in the container
and in Supabase are internally different roles; without this flag, the
restore can fail when it tries to `ALTER OWNER` to a role that doesn't exist
in Supabase.

## 5. Verify

Count the rows, pointed at the Supabase connection string:

```bash
psql "postgresql://postgres:@db.<ref>.supabase.co:5432/postgres" -c "
  SELECT 'dim_date', count(*) FROM dim_date
  UNION ALL SELECT 'dim_product', count(*) FROM dim_product
  UNION ALL SELECT 'dim_customer', count(*) FROM dim_customer
  UNION ALL SELECT 'dim_store', count(*) FROM dim_store
  UNION ALL SELECT 'fact_sales', count(*) FROM fact_sales;"
```

Or check directly in **Supabase Studio → Table Editor**. Expected row counts
(730 / 400 / 2,000 / 40 / 60,000) are listed in
[`retailStarSchema.md`](../data/retailStarSchema.md).

## 6. Things to watch out for

- **Never commit the Supabase password/connection string to git.** Keep it in
  `.env` or in `secrets/database_url.txt`; both are already gitignored. The
  repo has no `.env.example`, so the only variable the ETL tooling reads is
  `DATABASE_URL` (see [`connection/connectdb.py`](../../connection/connectdb.py)),
  and the GitHub Actions ETL workflow takes the same URL from the repository
  secret `URL`.
- After this, `retailspg` (Docker) and Supabase become **two separate
  databases** — loading data into Supabase doesn't automatically sync back
  to `retailspg`, and vice versa. Decide which one is the source of truth for
  the CSVs going forward.
- Free-tier Supabase projects auto-pause after ~1 week of inactivity — the
  first connection after a pause takes a few extra seconds to "wake up".