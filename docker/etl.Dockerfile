# SQL-only ETL runner. The pipeline is plain psql + .sql files, so the only
# thing the image needs is a psql client — postgres:16-alpine keeps it small
# and the client version matched to the postgres:16 service in compose.yaml.
FROM postgres:16-alpine

WORKDIR /app

# Install just the pipeline. data/, secrets/, .env and the notebooks stay out
# of the build context via .dockerignore; data/ is bind-mounted at run time.
COPY etl/ ./etl/
COPY docker/run-etl.sh ./run-etl.sh

# Documented override (docs/dataAnalytics/dataEngineering.md): if a purpose-built
# raw_sales.csv exists it is loaded with \copy; otherwise run-etl.sh derives the
# sale_id/category pairs from staging.fact_sales. data/ is mounted, not baked in.
ENV RAW_SALES_CSV=/app/data/raw/raw_sales.csv

CMD ["sh", "run-etl.sh"]
