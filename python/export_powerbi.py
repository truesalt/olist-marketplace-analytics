"""Export the star schema + marts to CSV for Power BI, and keep the Power BI kit in sync.

    python python/export_powerbi.py

1. Exports 9 tables to powerbi/data/<name>.csv (UTF-8, comma, header, ISO dates, '.' decimals,
   integers without '.0', NULL -> empty) and prints row counts.
2. Writes powerbi/data/_manifest.csv (file, rows, columns) and powerbi/data/_schema.csv
   (file, column, mysql_type, power_query_type) taken from information_schema - the real types.
3. Regenerates powerbi/power_query_M.md from that schema (every column explicitly typed).
4. Checks that every table[column] referenced in powerbi/DAX_measures.md exists in the export.
"""
from __future__ import annotations

import re
import sys
import time
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
from db import REPO_ROOT, get_engine  # noqa: E402

OUT_DIR = REPO_ROOT / "powerbi" / "data"
M_DOC = REPO_ROOT / "powerbi" / "power_query_M.md"
DAX_DOC = REPO_ROOT / "powerbi" / "DAX_measures.md"

# Power BI table name -> MySQL source (views are the star schema, marts are pre-aggregated)
EXPORTS = {
    "dim_date": "dim_date",
    "dim_customer": "v_dim_customer",
    "dim_seller": "v_dim_seller",
    "dim_product": "v_dim_product",
    "fact_order_items": "v_fact_order_items",
    "fact_seller_leads": "v_fact_seller_leads",
    "mart_cohort_retention": "mart_cohort_retention",
    "mart_pareto_sellers": "mart_pareto_sellers",
    "mart_lane_sla": "mart_lane_sla",
}

INTEGER_TYPES = {"tinyint", "smallint", "mediumint", "int", "bigint"}
MONEY_COLUMNS = {"price", "freight_value", "item_gmv", "gmv", "first_order_value", "total_gmv",
                 "gmv_first_90d"}

# One line per table for the "Applied steps" explanation in power_query_M.md
TABLE_NOTES = {
    "dim_date": "Calendar 2016-09-01..2018-12-31 (one row per day). Mark as date table on [date]; "
                "sort month_name by month_num.",
    "dim_customer": "One row per person (customer_unique_id) with first-order facts, repeat flags, RFM segment.",
    "dim_seller": "One row per seller with region, first/last sale month and acquisition channel.",
    "dim_product": "One row per product with English category, weight and volume.",
    "fact_order_items": "Main fact, one row per order item; order-level fields repeated on each item "
                        "(use DISTINCTCOUNT(order_id) for order measures).",
    "fact_seller_leads": "One row per marketing-qualified lead with funnel outcome flags (no relationships).",
    "mart_cohort_retention": "Cohort x months_since retention, long format, fractions 0-1 (no relationships).",
    "mart_pareto_sellers": "Seller GMV rank and cumulative share for the Pareto curve (no relationships).",
    "mart_lane_sla": "Seller-state -> customer-state delivery SLA, fractions 0-1 (no relationships).",
}


def power_query_type(column: str, mysql_type: str) -> str:
    """Map a MySQL data type to the Power Query type used in Table.TransformColumnTypes."""
    if mysql_type in INTEGER_TYPES:
        return "Int64.Type"
    if mysql_type in {"decimal", "double", "float"}:
        return "Currency.Type" if column in MONEY_COLUMNS else "type number"
    if mysql_type == "date":
        return "type date"
    if mysql_type in {"datetime", "timestamp"}:
        return "type datetime"
    return "type text"


def column_types(conn, source: str) -> list[tuple[str, str]]:
    rows = conn.exec_driver_sql(
        "SELECT column_name, data_type FROM information_schema.columns "
        f"WHERE table_schema = DATABASE() AND table_name = '{source}' ORDER BY ordinal_position").fetchall()
    return [(r[0], r[1].lower()) for r in rows]


def export_tables(engine) -> tuple[pd.DataFrame, pd.DataFrame]:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    manifest, schema = [], []
    with engine.connect() as conn:
        for name, source in EXPORTS.items():
            start = time.perf_counter()
            types = column_types(conn, source)
            # Explicit column list (no SELECT *): the export always matches the documented schema.
            cols = ", ".join(f"`{c}`" for c, _ in types)
            result = conn.exec_driver_sql(f"SELECT {cols} FROM {source}",
                                          execution_options={"no_parameters": True})
            df = pd.DataFrame(result.fetchall(), columns=list(result.keys()))
            for col, mysql_type in types:
                if mysql_type in INTEGER_TYPES:
                    df[col] = pd.to_numeric(df[col]).astype("Int64")      # 1, not 1.0; NULL -> empty
                schema.append({"file": f"{name}.csv", "column": col, "mysql_type": mysql_type,
                               "power_query_type": power_query_type(col, mysql_type)})
            # DATE values -> YYYY-MM-DD, DATETIME -> YYYY-MM-DD HH:MM:SS (both ISO 8601)
            df.to_csv(OUT_DIR / f"{name}.csv", index=False, encoding="utf-8")
            manifest.append({"file": f"{name}.csv", "rows": len(df), "columns": len(df.columns)})
            print(f"{name + '.csv':28s} {len(df):>9,} rows  {len(df.columns):>3} cols  "
                  f"({time.perf_counter() - start:4.1f}s)  <- {source}")
    manifest_df, schema_df = pd.DataFrame(manifest), pd.DataFrame(schema)
    manifest_df.to_csv(OUT_DIR / "_manifest.csv", index=False)
    schema_df.to_csv(OUT_DIR / "_schema.csv", index=False)
    return manifest_df, schema_df


def write_power_query_doc(schema: pd.DataFrame, manifest: pd.DataFrame) -> None:
    """Regenerate powerbi/power_query_M.md: one complete M script per exported CSV."""
    rows = dict(zip(manifest["file"], manifest["rows"]))
    out = [
        "# Power Query M scripts",
        "",
        "Generated by `python/export_powerbi.py` from the **actual** export schema",
        "(`powerbi/data/_schema.csv`, taken from MySQL `information_schema`). Do not edit by hand. "
        "Re-run `make export`.",
        "",
        "## 1. Parameter `DataFolder`",
        "Home → Manage Parameters → New parameter: **Name** `DataFolder`, **Type** Text, **Current value** "
        "the folder that holds the CSVs, e.g. `C:\\olist\\powerbi\\data\\` (keep the trailing backslash).",
        "",
        "## 2. One query per table",
        "For each block: Home → New Source → Blank Query → Advanced Editor → paste → Done → rename the query "
        "to the table name in the heading. Types use culture `en-US` (dot decimal separator).",
        "",
        "**Applied steps (same pattern for every table):** `Source` reads the UTF-8 CSV (`Encoding=65001`, "
        "quoted fields allowed) → `Promoted` turns the first row into headers → `Typed` sets an explicit type "
        "on every column (whole number, fixed decimal for money, decimal, date, date/time, text) so Power BI "
        "never guesses → `Renamed` is intentionally empty because the export already uses clean snake_case names.",
        "",
    ]
    for file_name, group in schema.groupby("file", sort=False):
        table = file_name[:-4]
        type_lines = ",\n        ".join(f'{{"{c}", {t}}}' for c, t in zip(group["column"], group["power_query_type"]))
        out += [
            f"### {table}  ({rows[file_name]:,} rows, {len(group)} columns)",
            TABLE_NOTES[table],
            "",
            "```powerquery",
            "let",
            f'    Source = Csv.Document(File.Contents(DataFolder & "{file_name}"),',
            '        [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),',
            "    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),",
            "    Typed = Table.TransformColumnTypes(Promoted, {",
            f"        {type_lines}",
            '    }, "en-US"),',
            "    // Column names are already clean snake_case: nothing to rename (kept as an explicit step).",
            "    Renamed = Table.RenameColumns(Typed, {})",
            "in",
            "    Renamed",
            "```",
            "",
        ]
    M_DOC.write_text("\n".join(out))
    print(f"wrote {M_DOC.relative_to(REPO_ROOT)}")


def check_dax_columns(schema: pd.DataFrame) -> int:
    """Every table[column] in DAX_measures.md must exist in the export (or be a model object)."""
    if not DAX_DOC.exists():
        print("DAX check skipped: powerbi/DAX_measures.md not found")
        return 0
    text = DAX_DOC.read_text()
    blocks = "\n".join(re.findall(r"```DAX\n(.*?)```", text, flags=re.S))
    refs = set(re.findall(r"'?([A-Za-z_][A-Za-z0-9_ ]*?)'?\[([^\]]+)\]", blocks))
    known = {(f[:-4], c) for f, c in zip(schema["file"], schema["column"])}
    model_objects = {("Top N", "Top N Value"), ("Top N", "Top N")}          # what-if parameter
    tables = {f[:-4] for f in schema["file"]}
    missing = sorted((t, c) for t, c in refs if t in tables and (t, c) not in known)
    unknown_tables = sorted((t, c) for t, c in refs if t not in tables and (t, c) not in model_objects)
    for t, c in missing + unknown_tables:
        print(f"DAX check: {t}[{c}] NOT FOUND", file=sys.stderr)
    checked = len([r for r in refs if r[0] in tables])
    print(f"DAX check: {checked} table[column] references verified against the export, "
          f"{len(missing) + len(unknown_tables)} problems")
    return 1 if (missing or unknown_tables) else 0


def main() -> int:
    engine = get_engine()
    manifest, schema = export_tables(engine)
    write_power_query_doc(schema, manifest)
    status = check_dax_columns(schema)
    print(f"manifest: powerbi/data/_manifest.csv ({manifest['rows'].sum():,} rows in {len(manifest)} files)")
    return status


if __name__ == "__main__":
    sys.exit(main())
