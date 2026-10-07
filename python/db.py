"""Database connection helper shared by every Python script and the notebook.

get_engine() builds a SQLAlchemy engine for the MySQL database described in .env
(MYSQL_HOST, MYSQL_PORT, MYSQL_USER, MYSQL_PASSWORD, MYSQL_DB).
URL.create() escapes special characters in the password, and pool_pre_ping=True
re-checks pooled connections before use so a long notebook never hits a stale one.
"""
from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv
from sqlalchemy import create_engine
from sqlalchemy.engine import URL, Engine

REPO_ROOT = Path(__file__).resolve().parents[1]


def get_engine(echo: bool = False) -> Engine:
    """Return a SQLAlchemy engine (mysql+pymysql) configured from the repo's .env file."""
    load_dotenv(REPO_ROOT / ".env")
    url = URL.create(
        drivername="mysql+pymysql",
        username=os.environ["MYSQL_USER"],
        password=os.environ.get("MYSQL_PASSWORD", ""),
        host=os.environ.get("MYSQL_HOST", "127.0.0.1"),
        port=int(os.environ.get("MYSQL_PORT", "3306")),
        database=os.environ.get("MYSQL_DB", "olist"),
        query={"charset": "utf8mb4"},
    )
    return create_engine(url, pool_pre_ping=True, echo=echo)


if __name__ == "__main__":
    # Smoke test: `python python/db.py` prints the server version.
    with get_engine().connect() as conn:
        version = conn.exec_driver_sql("SELECT VERSION()").scalar()
    print(f"Connected OK - MySQL {version}")
