# Retail Analytics Platform


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

  More detailed usage guides are in the [`docs/`](./docs) folder:

  - [`docs/data-integration-docker.md`](./docs/setup/Data-Integration-Docker.md) —
  how to integrate data using Docker
  - [`docs/docker.md`](./docs/setup/Docker.md) — how to set up and run the project's
  Docker environment
  - [`docs/supabase-migration.md`](./docs/setup/Supabase-Migration.md) — how to
  migrate the database with Supabase
  - [`docs/schemaDiagram.png`](./docs/setup/schemaDiagram.png) — visualization of the
  relationships between tables.

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
2. (Data Engineer) Start the environment via Docker
   ```bash
   docker compose up -d
   ```
3. (Data Analyst) Open the dashboard / notebook according to the instructions in each folder.

## Workflow

1. **Data Engineer** prepares raw data → ETL → clean data in the database.
2. **Data Analyst** takes the clean data → analysis → dashboard & insights.
3. Changes are made in individual branches, then submitted via Pull Request for review before merging into `main`.

## Tech Stack

| Category | Tools |
|---|---|
| ETL / Data Engineering | PostgreSQL / SQL |
| Database | PostgreSQL |
| Dashboard / BI | Tableau |
| Infrastructure | Docker, GitHub |
