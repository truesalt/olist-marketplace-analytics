"""Run the analysis SQL files and save every result set as a CSV.

Each file in sql/analysis/a*.sql contains SET statements (config -> user variables) and
queries preceded by a marker comment:

    -- @query: monthly_trend
    WITH ... SELECT ...;

Every marked query is executed and saved to results/sql/<file_stem>__<name>.csv.
All statements of one file run on ONE connection, because MySQL user variables (@ws ...)
only live inside the session that set them.

Usage:
    python python/run_analysis.py              # all files a01..a20
    python python/run_analysis.py --only a04   # files whose name starts with a04
    python python/run_analysis.py --quality    # sql/setup/07 audit; exit 1 on any FAIL row
"""
from __future__ import annotations

import argparse
import re
import sys
import time
from pathlib import Path

import pandas as pd
from tabulate import tabulate

sys.path.insert(0, str(Path(__file__).resolve().parent))
from db import REPO_ROOT, get_engine  # noqa: E402

ANALYSIS_DIR = REPO_ROOT / "sql" / "analysis"
QUALITY_FILE = REPO_ROOT / "sql" / "setup" / "07_data_quality_audit.sql"
RESULTS_DIR = REPO_ROOT / "results" / "sql"

MARKER = re.compile(r"^--\s*@query:\s*([a-z0-9_]+)\s*$")
QUERY_STARTS = ("SELECT", "WITH", "(")     # analysis files may only run queries ...
SESSION_STARTS = ("SET", "USE")            # ... plus session statements


def split_statements(sql_text: str) -> list[tuple[str, str | None]]:
    """Split a SQL script into (statement, query_name) pairs.

    A small character-by-character scanner, so that ';' or '--' inside a string literal
    (e.g. SEPARATOR '; ') is never mistaken for a statement end or a comment.
    Comments are removed; a '-- @query: name' comment names the statement that follows it.
    """
    statements: list[tuple[str, str | None]] = []
    buf: list[str] = []
    pending_name: str | None = None
    i, n = 0, len(sql_text)

    while i < n:
        ch = sql_text[i]
        nxt = sql_text[i + 1] if i + 1 < n else ""

        # String literal or quoted identifier: copy verbatim up to the closing quote.
        if ch in ("'", '"', "`"):
            j = i + 1
            while j < n:
                if sql_text[j] == "\\" and ch != "`":       # backslash escape inside a string
                    j += 2
                    continue
                if sql_text[j] == ch:
                    if j + 1 < n and sql_text[j + 1] == ch:   # doubled quote = literal quote
                        j += 2
                        continue
                    break
                j += 1
            buf.append(sql_text[i:j + 1])
            i = j + 1
            continue

        # Line comment: MySQL needs '-- ' (dash dash whitespace) or '#'.
        if (ch == "-" and nxt == "-" and (i + 2 >= n or sql_text[i + 2] in " \t\r\n")) or ch == "#":
            j = sql_text.find("\n", i)
            j = n if j == -1 else j
            marker = MARKER.match(sql_text[i:j].strip())
            if marker:
                if "".join(buf).strip():
                    raise ValueError(f"'@query: {marker.group(1)}' marker found inside a statement")
                pending_name = marker.group(1)
            i = j
            continue

        # Block comment /* ... */
        if ch == "/" and nxt == "*":
            j = sql_text.find("*/", i + 2)
            if j == -1:
                raise ValueError("unterminated /* comment")
            buf.append(" ")
            i = j + 2
            continue

        # Statement terminator
        if ch == ";":
            stmt = "".join(buf).strip()
            if stmt:
                statements.append((stmt, pending_name))
                pending_name = None
            buf = []
            i += 1
            continue

        buf.append(ch)
        i += 1

    tail = "".join(buf).strip()
    if tail:
        statements.append((tail, pending_name))
    return statements


def run_file(engine, path: Path) -> list[dict]:
    """Execute one SQL file; save each named query to CSV; return per-query stats."""
    stats = []
    statements = split_statements(path.read_text(encoding="utf-8"))
    with engine.connect() as conn:
        for stmt, name in statements:
            first_word = stmt.lstrip("(").split(None, 1)[0].upper() if not stmt.startswith("(") else "("
            # no_parameters: pass the SQL verbatim so '%' in DATE_FORMAT is not read as a placeholder
            opts = {"no_parameters": True}
            if name is None:
                if first_word not in SESSION_STARTS:
                    raise ValueError(f"{path.name}: statement has no '-- @query:' marker: {stmt[:70]}...")
                conn.exec_driver_sql(stmt, execution_options=opts)
                continue
            if first_word not in QUERY_STARTS:
                raise ValueError(f"{path.name}/{name}: only SELECT/WITH allowed, got {first_word}")
            start = time.perf_counter()
            result = conn.exec_driver_sql(stmt, execution_options=opts)
            df = pd.DataFrame(result.fetchall(), columns=list(result.keys()))
            seconds = time.perf_counter() - start
            out_file = RESULTS_DIR / f"{path.stem}__{name}.csv"
            df.to_csv(out_file, index=False)
            stats.append({"file": path.name, "query": name, "rows": len(df),
                          "seconds": round(seconds, 2), "df": df})
    return stats


def run_quality(engine) -> int:
    """Run the data-quality audit, print it, and return 1 if any check FAILed."""
    stats = run_file(engine, QUALITY_FILE)
    report = stats[0]["df"]
    print(tabulate(report, headers="keys", tablefmt="github", showindex=False))
    # Also keep the cleaning-rule log from 06 next to the audit (source of docs/data_quality_log.md).
    with engine.connect() as conn:
        result = conn.exec_driver_sql("SELECT rule_id, table_name, description, rows_affected, logged_at "
                                      "FROM dq_log ORDER BY log_id")
        pd.DataFrame(result.fetchall(), columns=list(result.keys())).to_csv(
            RESULTS_DIR / "06_transform_load_core__dq_log.csv", index=False)
    counts = report["status"].value_counts().to_dict()
    print(f"\nPASS={counts.get('PASS', 0)}  WARN={counts.get('WARN', 0)}  FAIL={counts.get('FAIL', 0)}")
    if counts.get("FAIL", 0):
        print("Data quality audit FAILED - fix the FAIL rows before building the model.", file=sys.stderr)
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--only", help="run only files whose name starts with this prefix, e.g. a04")
    parser.add_argument("--quality", action="store_true", help="run the 07 data-quality audit instead")
    args = parser.parse_args()

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    engine = get_engine()
    if args.quality:
        return run_quality(engine)

    files = sorted(ANALYSIS_DIR.glob("a*.sql"))
    if args.only:
        files = [f for f in files if f.name.startswith(args.only)]
    if not files:
        print("No analysis files matched.", file=sys.stderr)
        return 1

    all_stats, errors = [], []
    for path in files:
        for old_csv in RESULTS_DIR.glob(f"{path.stem}__*.csv"):   # drop stale outputs first
            old_csv.unlink()
        try:
            all_stats.extend(run_file(engine, path))
        except Exception as exc:  # report and keep going, fail at the end
            errors.append(f"{path.name}: {exc}")

    table = [{k: v for k, v in s.items() if k != "df"} for s in all_stats]
    print(tabulate(table, headers="keys", tablefmt="github"))
    empty = [f"{s['file']}/{s['query']}" for s in all_stats if s["rows"] == 0]
    for e in errors:
        print(f"ERROR  {e}", file=sys.stderr)
    for e in empty:
        print(f"EMPTY  {e} returned no rows", file=sys.stderr)
    print(f"\n{len(all_stats)} queries from {len(files)} files, "
          f"{sum(s['seconds'] for s in all_stats):.1f}s, {len(errors)} errors, {len(empty)} empty")
    return 1 if errors or empty else 0


if __name__ == "__main__":
    sys.exit(main())
