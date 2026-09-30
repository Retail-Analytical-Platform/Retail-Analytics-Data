import os
import sys
from pathlib import Path

import pandas as pd
from connectdb import get_engine  

STAGING = Path(os.getenv("ETL_STAGING_DIR", "data/staging"))
RAW_CSV = Path(os.getenv("RAW_SALES_CSV", "data/raw/raw_sales.csv"))
TABLES = ["dim_date", "dim_product", "dim_customer", "dim_store", "fact_sales"]


def extract_tables(engine) -> None:
    for table in TABLES:
        df = pd.read_sql(f"SELECT * FROM public.{table}", engine)
        df.to_csv(STAGING / f"{table}.csv", index=False)
        print(f"[extract] {table:<13} {len(df):>7,} rows")


def extract_raw_csv() -> None:
    if not RAW_CSV.exists():
        sys.exit(f"[extract] ERROR: raw CSV not found at {RAW_CSV} (set RAW_SALES_CSV)")
    raw = pd.read_csv(RAW_CSV, dtype=str)
    raw.columns = raw.columns.str.strip().str.lower()

    missing = {"sale_id", "category"} - set(raw.columns)
    if missing:
        sys.exit(f"[extract] ERROR: raw CSV is missing columns: {sorted(missing)}")
    if raw["sale_id"].duplicated().any():
        sys.exit("[extract] ERROR: raw CSV has duplicate sale_id values")

    raw.to_csv(STAGING / "raw_sales.csv", index=False)
    print(f"[extract] raw_sales    {len(raw):>7,} rows")


def main() -> None:
    STAGING.mkdir(parents=True, exist_ok=True)
    extract_tables(get_engine())
    extract_raw_csv()
    print(f"[extract] done -> {STAGING.resolve()}")


if __name__ == "__main__":
    main()
