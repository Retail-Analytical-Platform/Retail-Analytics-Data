FROM postgres:16-alpine

WORKDIR /app

# Install the SQL files and the runner. data/, secrets/, .env and notebooks
COPY etl/*.sql /app/etl/
COPY etl/run_etl.sh /app/etl/run_etl.sh

ENV RAW_SALES_CSV=/app/data/raw/raw_sales.csv

CMD ["sh", "/app/etl/run_etl.sh"]