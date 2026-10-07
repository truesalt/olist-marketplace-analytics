"""Fallback staging loader: CSV -> stg_* tables with pandas.

Use this only if `make load` (LOAD DATA LOCAL INFILE) fails or a staging row count
is off by more than 1% (e.g. local_infile disabled on a managed server).

It mirrors 02_load_staging.sql exactly:
  * every value is read as a string (dtype=str) and empty fields stay '' instead of
    NaN (keep_default_na=False) - the same raw text that LOAD DATA would store;
  * encoding='utf-8-sig' strips the BOM from product_category_name_translation.csv;
  * each staging table is TRUNCATEd and then appended to in chunks of 10,000 rows.

Usage:
    python python/load_fallback.py                         # all 11 tables
    python python/load_fallback.py --only stg_sellers stg_mql
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
from db import REPO_ROOT, get_engine  # noqa: E402

RAW_DIR = REPO_ROOT / "data" / "raw"

# staging table -> source CSV (CSV headers already equal the staging column names)
FILES = {
    "stg_orders": "olist_orders_dataset.csv",
    "stg_order_items": "olist_order_items_dataset.csv",
    "stg_order_payments": "olist_order_payments_dataset.csv",
    "stg_order_reviews": "olist_order_reviews_dataset.csv",
    "stg_customers": "olist_customers_dataset.csv",
    "stg_sellers": "olist_sellers_dataset.csv",
    "stg_products": "olist_products_dataset.csv",
    "stg_geolocation": "olist_geolocation_dataset.csv",
    "stg_category_translation": "product_category_name_translation.csv",
    "stg_mql": "olist_marketing_qualified_leads_dataset.csv",
    "stg_closed_deals": "olist_closed_deals_dataset.csv",
}


def load_table(engine, table: str, csv_name: str) -> int:
    """Truncate one staging table and reload it from its CSV; return the row count."""
    df = pd.read_csv(RAW_DIR / csv_name, dtype=str, keep_default_na=False, encoding="utf-8-sig")
    with engine.begin() as conn:
        conn.exec_driver_sql(f"TRUNCATE TABLE {table}")
    df.to_sql(table, engine, if_exists="append", index=False, chunksize=10_000)
    with engine.connect() as conn:
        return conn.exec_driver_sql(f"SELECT COUNT(*) FROM {table}").scalar()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--only", nargs="+", choices=sorted(FILES), help="load only these staging tables")
    args = parser.parse_args()

    engine = get_engine()
    tables = args.only or list(FILES)
    for table in tables:
        start = time.perf_counter()
        rows = load_table(engine, table, FILES[table])
        print(f"{table:26s} {rows:>9,} rows  ({time.perf_counter() - start:5.1f}s)")
    print("Fallback load complete - record 'pandas fallback' in docs/data_quality_log.md.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
