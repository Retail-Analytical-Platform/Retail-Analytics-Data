# Retail Analytics Platform

## Team & Roles

This project is carried out collaboratively with the following division of responsibilities:

### Data Analyst
- Business model analysis
- Building dashboards
- Defining KPIs
- Compiling business insights & recommendations

### Data Engineer
- GitHub & Docker setup
- Building the ETL pipeline
- Data cleaning & transformation
- Database management

## Documentation

  More detailed usage guides are available in the [`docs/`](./docs) folder:

  - [`docs/data-integration-docker.md`](./docs/Data-Integration-Docker.md) —
  how to integrate data using Docker
  - [`docs/docker.md`](./docs/Docker.md) — how to set up & run the project's
  Docker environment
  - [`docs/supabase-migration.md`](./docs/Supabase-Migration.md) — how to
  migrate the database with Supabase

## Repository Structure

```
.
├── data/               # Raw & processed data
├── src/                # Exploration & analysis notebooks
├── etl/                # ETL pipeline scripts (Data Engineer)
├── dashboard/          # Dashboard source (Data Analyst)
├── docker/             # Docker configuration
├── docs/               # Documentation, KPI definitions, insight reports
└── README.md
```

## How to Run

1. Clone the repository
   ```bash
   git clone https://github.com/<org-or-username>/<repo>.git
   cd <repo>
   ```
2. (Data Engineer) Run the environment via Docker
   ```bash
   docker compose up -d
   ```
3. (Data Analyst) Open the dashboard / notebook according to the instructions in each folder.

## Workflow

1. **Data Engineer** prepares raw data → ETL → clean data in the database.
2. **Data Analyst** takes the clean data → analysis → dashboard & insights.
3. Changes are made on individual branches, then submitted via Pull Request for review before merging into `main`.

## Tech Stack

| Category | Tools |
|---|---|
| ETL / Data Engineering | Python |
| Database | PostgreSQL |
| Dashboard / BI | Tableau |
| Infrastructure | Docker, GitHub |
