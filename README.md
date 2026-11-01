# Retail Analytics Platform

A retail star-schema dataset (one fact table, four dimensions) with a SQL ETL
pipeline that repairs the raw data into a cleaned `clean` schema, and
Tableau dashboards built on top of it.

## Team & Roles

This project is worked on collaboratively, with responsibilities split as follows:

### Data Analyst
- Business model analysis
- Building dashboards
- Defining KPIs
- Writing business insights & recommendations

### Data Engineer
- GitHub & Docker setup
- Building the ETL pipeline
- Data cleaning & transformation
- Database management

## Documentation

More detailed guides are in the [`docs/`](./docs) folder.

**Setup**

- [`docs/setup/Docker.md`](./docs/setup/Docker.md) — set up the Docker
  environment: database, secrets, the `etl` service
- [`docs/setup/Supabase-Migration.md`](./docs/setup/Supabase-Migration.md) —
  migrate the database to Supabase
- [`docs/setup/schemaDiagram.png`](./docs/setup/schemaDiagram.png) — relationships
  between the tables of the cleaned `clean` schema (source:
  [`schemaDiagram.dot`](./docs/setup/schemaDiagram.dot), render with Graphviz)

**Data and engineering**

- [`docs/data/retailStarSchema.md`](./docs/data/retailStarSchema.md) — the
  dataset: model, row counts, known issues in the raw files
- [`docs/dataEngineering/dataEngineering.md`](./docs/dataEngineering/dataEngineering.md) —
  the ETL pipeline, stage by stage
- [`docs/dataEngineering/PricingIssueFix.md`](./docs/dataEngineering/PricingIssueFix.md) —
  how `dim_product` prices were rebuilt

**Analytics**

- [`docs/dataAnalytics/Stakeholderinsight.md`](./docs/dataAnalytics/Stakeholderinsight.md) —
  stakeholder insight report
- [`docs/dataAnalytics/Doc for calculated field explanation.md`](./docs/dataAnalytics/Doc%20for%20calculated%20field%20explanation.md) —
  the Tableau calculated fields
- [`docs/dataAnalytics/earlyexplanation.md`](./docs/dataAnalytics/earlyexplanation.md) —
  early analysis notes

## Repository Structure

```
.
├── .github/workflows/   # CI: ETL reload (etl.yml) and Markdown link check (docs-links.yml)
├── connection/          # Python helpers: database engine and secret lookup
├── data/                # Raw star-schema CSVs, schema.sql, schema.yaml, brand prices
├── docker/              # etl.Dockerfile (the image behind the etl service)
├── docs/                # Setup guides, data and engineering docs, analytics docs
├── etl/                 # SQL pipeline (rules, extract, transform, load), run_etl.sh, notebook
├── scraped_data/        # eBay price scraper (scrape.py) and its output CSVs
├── tests/               # SQL assertions run after the pipeline
├── compose.yaml         # postgres service and the etl service (profile "etl")
├── requirements.txt     # Python dependencies for the notebook and scraper
├── CODE_OF_CONDUCT.md
├── CONTRIBUTING.md
├── LICENSE
├── SECURITY.md
└── README.md
```

## How to Run

You need Docker with the Compose plugin. The steps below are covered in detail
in [`docs/setup/Docker.md`](./docs/setup/Docker.md).

1. Clone the repository
   ```bash
   git clone https://github.com/Retail-Analytical-Platform/retail-analytics-data.git
   cd retail-analytics-data
   ```
2. Create the data volume. `compose.yaml` declares it as external, so Compose
   will not create it:
   ```bash
   docker volume create retailspg-data
   ```
3. Create the secrets. Both files are gitignored and read as Docker secrets:
   ```bash
   mkdir -p secrets
   openssl rand -base64 24 | tr -d '/+=' | head -c 24 > secrets/postgres_password.txt
   printf 'postgresql://postgres:%s@postgres:5432/postgres\n' \
     "$(cat secrets/postgres_password.txt)" > secrets/database_url.txt
   ```
   | File | Used by | Contents |
   |---|---|---|
   | `secrets/postgres_password.txt` | `postgres` service | password of the `postgres` role |
   | `secrets/database_url.txt` | `etl` service | connection URL; the host must be `postgres`, not `localhost` |
4. Start the database (listens on `127.0.0.1:5432`; set `POSTGRES_PORT` to change the port)
   ```bash
   docker compose up -d postgres
   ```
5. (Data Engineer) Run the ETL pipeline. The `etl` service is behind a Compose
   profile, so it only runs when asked for. On a fresh database it first loads
   the raw tables from `data/`, then builds the `staging`, `transformed` and
   `clean` schemas, and fails unless `clean.fact_sales` has 60,000 rows:
   ```bash
   docker compose --profile etl run --rm etl
   ```
   Add `--build` after `run` when files in `etl/` have changed.
6. (Data Analyst) Connect Tableau or any SQL client to `127.0.0.1:5432`, user
   `postgres`, the password from `secrets/postgres_password.txt`, and read from
   the `clean` schema.

**CI.** [`etl.yml`](./.github/workflows/etl.yml) re-runs the same pipeline
against a hosted database on every push to `main`. It needs one repository
secret, `URL`, holding that database's connection string.
[`docs-links.yml`](./.github/workflows/docs-links.yml) checks the Markdown links
in the repository on pull requests.

## Workflow

1. **Data Engineer** prepares raw data → ETL → clean data in the database.
2. **Data Analyst** takes the clean data → analysis → dashboard & insights.
3. Changes are made in individual branches, then submitted via Pull Request for review before merging into `main`.

## Tech Stack

| Category | Tools |
|---|---|
| Database | PostgreSQL 16 (local Docker container; Supabase for the hosted copy) |
| ETL / Data Engineering | SQL and PL/pgSQL functions run with `psql`; POSIX shell runner (`etl/run_etl.sh`); Jupyter notebook as the driver (`etl/main_pipeline.ipynb`) |
| Python | SQLAlchemy and psycopg2 for the notebook's database connection (`connection/`); the eBay scraper uses only the standard library. `requirements.txt` is a full pinned environment freeze, Jupyter included |
| Data source | Synthetic star schema ; eBay Browse API for market prices |
| Dashboard / BI | Tableau |
| Infrastructure | Docker and Docker Compose (secrets, healthcheck, profiles), GitHub, GitHub Actions |