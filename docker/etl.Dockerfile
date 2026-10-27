# SQL-only ETL runner. The pipeline is plain psql + .sql files, so the only
# thing the image needs is a psql client — postgres:16-alpine keeps it small
# and the client version matched to the postgres:16 service in compose.yaml.
FROM postgres:16-alpine

WORKDIR /app

# Install the SQL files and the runner. data/, secrets/, .env and notebooks
# stay out of the image; data/ is bind-mounted at run time.
COPY etl/*.sql /app/etl/
COPY etl/run_etl.sh /app/etl/run_etl.sh

# Documented override (docs/dataAnalytics/dataEngineering.md): if a purpose-built
# raw_sales.csv exists it is loaded with \copy; otherwise run-etl.sh derives the
# sale_id/category pairs from staging.fact_sales. data/ is mounted, not baked in.
ENV RAW_SALES_CSV=/app/data/raw/raw_sales.csv

CMD ["sh", "/app/etl/run_etl.sh"]
