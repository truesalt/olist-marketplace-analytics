# =============================================================================
# Makefile — olist-marketplace-analytics
# Run every target from the repo root:   make venv download all
#
# MySQL credentials come from .env and reach the mysql client through a
# temporary --defaults-extra-file (mktemp, chmod 600, deleted on exit), so the
# password never appears on the command line, in `ps`, or in any log.
# (GNU Make 3.81 compatible — the version that ships with macOS.)
# =============================================================================

SHELL   := /bin/bash
VENV    := .venv
PY      := $(VENV)/bin/python
NB      := notebooks/01_statistical_tests.ipynb
SETUP   := sql/setup

# Interpreter used only to create the venv. 3.11 is preferred because every
# pinned scientific package ships mature wheels for it; any 3.11+ works.
PY_BOOT ?= $(shell command -v python3.11 2>/dev/null || command -v python3 2>/dev/null)

# mysql client: whatever is on PATH, else Homebrew's keg-only mysql@8.4.
MYSQL   ?= $(shell command -v mysql 2>/dev/null || echo /opt/homebrew/opt/mysql@8.4/bin/mysql)

# Shell snippet (expanded inside recipes): load .env, write a private option file to $cnf.
LOAD_ENV_CNF = test -f .env || { echo "ERROR: .env missing - run: cp .env.example .env and set MYSQL_PASSWORD" >&2; exit 1; }; \
	set -a; . ./.env; set +a; \
	cnf="$$(mktemp)"; chmod 600 "$$cnf"; trap 'rm -f "$$cnf"' EXIT; \
	printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword="%s"\n' \
	  "$$MYSQL_HOST" "$$MYSQL_PORT" "$$MYSQL_USER" "$$MYSQL_PASSWORD" > "$$cnf"

MYSQL_RUN = "$(MYSQL)" --defaults-extra-file="$$cnf" --local-infile=1

# $(call run_sql,<file>,<database or empty>) : run one SQL file, print results as tables.
run_sql = @set -eo pipefail; $(LOAD_ENV_CNF); echo ">>> $(1)"; \
	$(MYSQL_RUN) --table --show-warnings $(2) < "$(1)"

.PHONY: help venv download db-user db load load-fallback core quality perf model \
        analysis stats charts export all clean-db

help:
	@echo "Targets (run in this order the first time):"
	@echo "  make venv          create .venv and install requirements.txt"
	@echo "  make download      Kaggle CLI -> data/raw (needs ~/.kaggle credentials)"
	@echo "  make db-user       ONE-TIME as MySQL root: server settings + app user from .env"
	@echo "  make all           db load core quality perf model analysis stats export"
	@echo "  make clean-db      DROP DATABASE (asks for confirmation; CONFIRM=yes skips the prompt)"
	@echo "Individual steps: db load load-fallback core quality perf model analysis stats charts export"

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
venv:
	@$(PY_BOOT) -c 'import sys; assert sys.version_info >= (3, 11), "Python 3.11+ required"'
	$(PY_BOOT) -m venv $(VENV)
	$(PY) -m pip install --quiet --upgrade pip
	$(PY) -m pip install --quiet -r requirements.txt
	@echo "venv ready: $$($(PY) --version)"

download:
	@mkdir -p data/raw
	$(VENV)/bin/kaggle datasets download -d olistbr/brazilian-ecommerce -p data/raw --unzip
	$(VENV)/bin/kaggle datasets download -d olistbr/marketing-funnel-olist -p data/raw --unzip
	@echo "$$(ls -1 data/raw/*.csv | wc -l | tr -d ' ') CSV files in data/raw (expected 11)"

# One-time server preparation, run as MySQL root (prompts for the root password;
# a fresh Homebrew install has none - just press Enter). Idempotent.
ROOT_USER ?= root
db-user:
	@set -eo pipefail; set -a; . ./.env; set +a; \
	printf "%s\n" \
	  "SET PERSIST local_infile = ON;" \
	  "SET PERSIST cte_max_recursion_depth = 5000;" \
	  "SET PERSIST log_bin_trust_function_creators = 1;" \
	  "CREATE USER IF NOT EXISTS '$$MYSQL_USER'@'localhost' IDENTIFIED BY '$$MYSQL_PASSWORD';" \
	  "CREATE USER IF NOT EXISTS '$$MYSQL_USER'@'127.0.0.1' IDENTIFIED BY '$$MYSQL_PASSWORD';" \
	  "GRANT ALL PRIVILEGES ON \`$$MYSQL_DB\`.* TO '$$MYSQL_USER'@'localhost';" \
	  "GRANT ALL PRIVILEGES ON \`$$MYSQL_DB\`.* TO '$$MYSQL_USER'@'127.0.0.1';" \
	  "SELECT VERSION() AS mysql_version;" \
	| "$(MYSQL)" -h "$$MYSQL_HOST" -P "$$MYSQL_PORT" -u $(ROOT_USER) -p

# ---------------------------------------------------------------------------
# Database build (each step is idempotent and can be re-run on its own)
# ---------------------------------------------------------------------------
db:
	$(call run_sql,$(SETUP)/00_create_database.sql,)
	$(call run_sql,$(SETUP)/01_staging_schema.sql,"$$MYSQL_DB")

load:
	$(call run_sql,$(SETUP)/02_load_staging.sql,"$$MYSQL_DB") \
	  || { echo "LOAD DATA failed - try the pandas loader: make load-fallback" >&2; exit 1; }

load-fallback:
	$(PY) python/load_fallback.py

core:
	$(call run_sql,$(SETUP)/03_core_schema.sql,"$$MYSQL_DB")
	$(call run_sql,$(SETUP)/04_functions.sql,"$$MYSQL_DB")
	$(call run_sql,$(SETUP)/05_procedures.sql,"$$MYSQL_DB")
	$(call run_sql,$(SETUP)/06_transform_load_core.sql,"$$MYSQL_DB")

# Runs 07 through the Python runner: prints the audit, saves the CSV, exits 1 on any FAIL row.
quality:
	$(PY) python/run_analysis.py --quality

# EXPLAIN ANALYZE output is multi-line text, so this step prints raw (unboxed) output
# and keeps a copy in results/perf/ for docs/performance.md.
perf:
	@mkdir -p results/perf
	@set -eo pipefail; $(LOAD_ENV_CNF); echo ">>> $(SETUP)/08_indexes_performance.sql"; \
	$(MYSQL_RUN) --raw --show-warnings "$$MYSQL_DB" < $(SETUP)/08_indexes_performance.sql \
	  | tee results/perf/08_explain_analyze.txt

model:
	$(call run_sql,$(SETUP)/09_star_schema_views.sql,"$$MYSQL_DB")
	$(call run_sql,$(SETUP)/10_marts.sql,"$$MYSQL_DB")

# ---------------------------------------------------------------------------
# Analysis, statistics, exports
# ---------------------------------------------------------------------------
analysis:
	$(PY) python/run_analysis.py

stats:
	$(VENV)/bin/jupyter nbconvert --execute --to notebook --inplace \
	  --ExecutePreprocessor.timeout=1800 $(NB)

charts:
	$(PY) python/make_charts.py

export:
	$(PY) python/export_powerbi.py

all: db load core quality perf model analysis stats export

# ---------------------------------------------------------------------------
# Danger zone
# ---------------------------------------------------------------------------
clean-db:
	@if [ "$(CONFIRM)" != "yes" ]; then \
	  read -r -p "This DROPS the whole analysis database. Type yes to continue: " ans; \
	  [ "$$ans" = "yes" ] || { echo "Aborted."; exit 1; }; \
	fi
	@set -eo pipefail; $(LOAD_ENV_CNF); \
	$(MYSQL_RUN) -e "DROP DATABASE IF EXISTS \`$$MYSQL_DB\`;"; \
	echo "Dropped database $$MYSQL_DB"
