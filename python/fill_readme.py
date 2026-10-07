"""Fill or check placeholders in README.md and docs/*.md (optional helper).

Placeholders
  {{TBD}}                                   -> a number still to be computed (reported by --check)
  {{csv|<path>|<column>|<row>}}             -> value from a results CSV; <row> is a 0-based index
  {{csv|<path>|<column>|<key_col>=<value>}} -> value from the row where key_col == value

Usage:
    python python/fill_readme.py --check    # list remaining {{...}} placeholders, exit 1 if any
    python python/fill_readme.py --fill     # replace every {{csv|...}} token in place
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import pandas as pd

REPO = Path(__file__).resolve().parents[1]
FILES = [REPO / "README.md", *sorted((REPO / "docs").glob("*.md"))]
TOKEN = re.compile(r"\{\{([^{}]+)\}\}")


def resolve(token: str) -> str | None:
    """Return the value for a {{csv|...}} token, or None if it is not a csv token."""
    parts = token.split("|")
    if len(parts) != 4 or parts[0] != "csv":
        return None
    _, path, column, row = parts
    df = pd.read_csv(REPO / path)
    if "=" in row:
        key, value = row.split("=", 1)
        match = df[df[key].astype(str) == value]
        return str(match.iloc[0][column])
    return str(df.iloc[int(row)][column])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", action="store_true")
    group.add_argument("--fill", action="store_true")
    args = parser.parse_args()

    remaining = 0
    for path in FILES:
        text = path.read_text(encoding="utf-8")
        if args.fill:
            text = TOKEN.sub(lambda m: resolve(m.group(1)) or m.group(0), text)
            path.write_text(text, encoding="utf-8")
        for m in TOKEN.finditer(text):
            remaining += 1
            line = text[: m.start()].count("\n") + 1
            print(f"{path.relative_to(REPO)}:{line}: {m.group(0)}")
    print(f"{remaining} placeholder(s) remaining")
    return 1 if remaining else 0


if __name__ == "__main__":
    sys.exit(main())
