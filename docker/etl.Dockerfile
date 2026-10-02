FROM postgres:16-alpine

WORKDIR /app

COPY etl/ ./etl/

ENV RAW_SALES_CSV=/app/data/raw/raw_sales.csv

CMD ["sh", "-ec", "DATABASE_URL=$(cat /run/secrets/database_url); psql \"$DATABASE_URL\" -v raw_sales_csv=\"$RAW_SALES_CSV\" -f etl/extract/extract.sql; psql \"$DATABASE_URL\" -f etl/transform/transform.sql; psql \"$DATABASE_URL\" -f etl/load/load.sql"]
