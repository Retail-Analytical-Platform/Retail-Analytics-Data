# Setting up PostgreSQL with Docker

This tutorial runs PostgreSQL locally via Docker so every team member can
practice queries against the same dataset (see [`data/`](../../data/) and its
description in [`retailStarSchema.md`](../data/retailStarSchema.md)), without
installing PostgreSQL directly on their own OS. It also covers the `etl`
service that builds the cleaned `clean` schema from that data.

## Table of Contents

1. [Install & enable Docker](#1-install--enable-docker)
2. [Run PostgreSQL in a container](#2-run-postgresql-in-a-container)
3. [Run the ETL pipeline](#3-run-the-etl-pipeline)
4. [Connect from VS Code (PostgreSQL extension)](#4-connect-from-vs-code-postgresql-extension)
5. [Everyday Docker commands](#5-everyday-docker-commands)

To load the raw `data/` CSVs by hand instead of through the ETL service →
[Data-Integration-Docker.md](Data-Integration-Docker.md)

---

## 1. Install & enable Docker

```bash
# start Docker now, and automatically on boot
sudo systemctl enable --now docker

# so the user can run docker without sudo
sudo usermod -aG docker "$USER"
```

After that, **log out and log back in** (or run `newgrp docker` in the current
terminal) for the group change to take effect. Check the installation:

```bash
docker run hello-world
```

## 2. Run PostgreSQL in a container

The `postgres` service is already defined in this repo's
[`compose.yaml`](../../compose.yaml), so there's no `docker run` command to
type. Two things must exist before the first start: the data volume and the
secret files.

### 2.1 Create the data volume

`compose.yaml` declares `retailAnalytics-data` as an **external** volume, so Compose
will not create it for you and fails with "external volume not found" if it is
missing. Create it once:

```bash
docker volume create retailAnalytics-data
```

### 2.2 Create the secrets

Neither secret is a plain environment variable. Both are **Docker secrets**,
read from local files instead of being stored in the compose file or visible in
`docker inspect`. Both files live in `secrets/`, which is gitignored
(`secrets/*` in `.gitignore`), so they stay local and are never committed.

| File | Used by | Contents |
|---|---|---|
| `secrets/postgres_password.txt` | `postgres` service | the password of the `postgres` role |
| `secrets/database_url.txt` | `etl` service | a full connection URL to the database |

`database_url.txt` must use the Compose service name `postgres` as the host,
not `localhost` — inside the ETL container, `localhost` is the ETL container
itself. Create both files in one go so the password matches:

```bash
mkdir -p secrets
openssl rand -base64 24 | tr -d '/+=' | head -c 24 > secrets/postgres_password.txt
printf 'postgresql://postgres:%s@postgres:port/postgres\n' \
  "$(cat secrets/postgres_password.txt)" > secrets/database_url.txt
```

PostgreSQL only reads `POSTGRES_PASSWORD_FILE` when it initializes an empty
volume. If `retailAnalytics-data` already holds a database, put **that database's
existing password** in both files instead of generating a new one.

### 2.3 Start the database

```bash
docker compose up -d postgres
```
**`postgres` service**

| Part | Purpose |
|---|---|
| `image: postgres:16` | the image used — PostgreSQL version 16 |
| `container_name: retailAnalytics` | names the container `retailAnalytics` (retail store postgres) — referenced throughout these docs |
| `restart: unless-stopped` | stays alive across reboots/crashes, similar in spirit to `docker run -d` |
| `POSTGRES_USER`, `POSTGRES_DB` | default to `postgres`; override by exporting the variable or putting it in a `.env` file next to `compose.yaml` |
| `POSTGRES_PASSWORD_FILE` | tells the `postgres` image to read its password from a file instead of an env var, so the plaintext value never appears in `docker inspect` or `docker compose config` |
| `ports: "host_port:${POSTGRES_PORT:-port}:port"` | maps `host:container` ports and binds the host side to loopback only, so the database is not reachable from other machines. `POSTGRES_PORT` changes the host port if port is taken |
| `retailAnalytics-data:/var/lib/postgresql/data` | named volume for storing data. `/var/lib/postgresql/data` is where PostgreSQL physically stores its tables, so if the container is removed, the data still lives in the `retailAnalytics-data` volume and can be reused once a new container is created |
| `secrets: postgres_password` | mounts the secret read-only at `/run/secrets/postgres_password` inside the container |
| `healthcheck` | runs `pg_isready` every 5 s (up to 12 retries). The `etl` service waits for it to pass |

**`etl` service**

| Part | Purpose |
|---|---|
| `depends_on: postgres: condition: service_healthy` | starts only after PostgreSQL reports healthy |
| `build` → `docker/etl.Dockerfile` | builds a `postgres:16-alpine` image (psql client only) containing `etl/*.sql` and `etl/run_etl.sh`; the pipeline is plain SQL, with no Python in the image |
| `secrets: database_url` | mounts `secrets/database_url.txt` at `/run/secrets/database_url`, which `run_etl.sh` reads as the connection string |
| `./data:/app/data` | bind-mounts the repo's `data/` folder (CSVs and `schema.sql`) into the container; `data/` is not baked into the image |
| `profiles: ["etl"]` | keeps the service out of a plain `docker compose up`; it only runs when requested with `--profile etl` |

**Top-level blocks**

| Part | Purpose |
|---|---|
| `secrets` | maps each secret name to its local file under `secrets/` |
| `volumes: retailAnalytics-data: external: true` | the volume is created outside Compose (see [2.1](#21-create-the-data-volume)), so `docker compose down -v` does not delete it |

```bash
docker compose up -d postgres  # run in the background
docker compose ps              # check status
docker compose logs -f postgres # view logs live
docker compose down            # stop the containers (the external volume is kept)
```

## 3. Run the ETL pipeline

With PostgreSQL running and both secret files in place:

```bash
docker compose --profile etl run --rm etl
```

Add `--build` after `run` to rebuild the image when files in `etl/` change.
`etl/run_etl.sh` then does the following, in order:

1. Waits up to 60 s for the database to accept connections.
2. If `public.fact_sales` does not exist, creates the `public` tables from
   [`data/schema.sql`](../../data/schema.sql) and loads the five CSVs from
   `data/`. No manual load step is needed.
3. Installs the SQL objects from `etl/rules.sql`, `extract.sql`,
   `transform.sql`, `load.sql` and `pipeline.sql`, in that order.
4. Loads `public.brand_data` from `data/brand_prices.csv` if it is empty.
5. Runs `etl.extract()`, fills `staging.raw_sales`, then `etl.run_pipeline()`
   (`etl.transform()` followed by `etl.load()`).
6. Fails unless `clean.fact_sales` has exactly 60,000 rows.

The result is the `staging`, `transformed` and `clean` schemas next to the raw
`public` tables. BI tools should read `clean`. The pipeline's design and
decisions are in
[`docs/dataEngineering/dataEngineering.md`](../dataEngineering/dataEngineering.md).

The same steps run in GitHub Actions from
[`.github/workflows/etl.yml`](../../.github/workflows/etl.yml), using the
repository secret `URL` as the connection string.

## 4. Connect from VS Code (PostgreSQL extension)

1. Install the **PostgreSQL** extension in VS Code.
2. Click the PostgreSQL icon (elephant icon) in the Activity Bar, or
   `Ctrl+Shift+P` → **PostgreSQL: New Connection**.
3. Fill in the connection form as below — match **Password** to the value in
   `secrets/postgres_password.txt`:

   | Field | Value |
   |---|---|
   | Host | `host_port` |
   | Port | `port` (or your `POSTGRES_PORT`) |
   | Username | `postgres` |
   | Password | the value in `secrets/postgres_password.txt` |
   | Database | `postgres` |

4. Click **Save**/**Connect**. The sidebar will show the database → schema →
   table tree.

## 5. Everyday Docker commands

```bash
docker ps                                            # view running containers
docker exec -it retailAnalytics psql -U postgres            # enter psql inside the container
docker stop retailAnalytics                                 # stop the container
docker start retailAnalytics                                # start it again (data persists via the volume)
docker rm -f retailAnalytics                                # remove the container (retailAnalytics-data volume persists)
docker volume rm retailAnalytics-data                       # delete the data too (container must be removed first)
```