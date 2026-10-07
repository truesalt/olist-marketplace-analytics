# PROJECT_SPEC.md — Olist Marketplace Health: Delivery, Discounts & Seller Supply

> **Instructions to Claude Code (read first, follow exactly).**
> 1. Read this entire file before writing any code. This file is the single source of truth. If something here conflicts with your defaults, this file wins.
> 2. Build in the phase order of §16. Do not start a phase until the previous phase's **Gate** checks pass.
> 3. **Never invent numbers.** Every figure in README, docs, resume bullets and interview prep must come from files in `results/`. If a number is not computed yet, leave `{{TBD}}` and come back.
> 4. Stop and ask the user only for: MySQL root/user password, Kaggle API token, permission to install system packages (brew/apt). Everything else is decided here.
> 5. After each phase: run its Gate, then `git commit` with the message given in §16.
> 6. Target DB: **MySQL 8.0.31+ (8.4 LTS preferred)**. Do not use PostgreSQL. Where MySQL lacks a feature, use the workaround in §13.
> 7. The owner (Nandhagopan Nair, B.Tech IIT (BHU) Varanasi, 2027) will be interviewed on every line. Code must be readable, commented, and explainable. Prefer clarity over cleverness.

---

## 1. Project summary

| Item | Value |
|---|---|
| Repo name | `olist-marketplace-analytics` |
| One-line pitch | End-to-end SQL (MySQL) + Python stats + Power BI analysis of a real Brazilian marketplace: how delivery performance, discounts and seller supply drive reviews, repeat purchases and GMV. |
| Stakeholder | Head of Marketplace Operations & Growth at Olist |
| Primary business question | **Which delivery failures, discount practices and seller-supply gaps are costing Olist 5-star reviews, repeat customers and GMV — and what should be fixed first?** |
| Sub-questions | (Q1) How healthy is the marketplace (GMV, orders, AOV, growth)? (Q2) Where and how badly is the delivery promise broken (lanes, sellers, categories)? (Q3) Does a late first order reduce reviews and repeat purchase? (Q4) Do voucher-paid first orders bring customers back? (Q5) Which seller-acquisition channels produce sellers that actually sell? (Q6) How concentrated is GMV (Pareto risk)? |
| Deliverables | MySQL database + 9 setup SQL files + 20 analysis SQL files, Python stats notebook, result CSVs + charts, Power BI build kit (CSVs, DAX, Power Query M, theme, build guide), recruiter-ready README, docs, interview prep |
| Audiences | DA/BA interviewers at consulting firms (ZS, EXL, Fractal, Tiger, Mu Sigma, Accenture) and product firms (Flipkart, Meesho, Swiggy, PhonePe, Amazon) |
| Owner environment | macOS or Linux for everything except Power BI Desktop (Windows-only; see §11.7) |

---

## 2. Datasets

### 2.1 Sources (both CC BY-NC-SA 4.0 — attribute Olist in README)
1. **Brazilian E-Commerce Public Dataset by Olist** — `https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce` (Kaggle slug `olistbr/brazilian-ecommerce`)
2. **Marketing Funnel by Olist** — `https://www.kaggle.com/datasets/olistbr/marketing-funnel-olist` (Kaggle slug `olistbr/marketing-funnel-olist`)

### 2.2 Download
- Preferred: Kaggle CLI. `pip install kaggle`; token at `~/.kaggle/kaggle.json` with `chmod 600`. Ask the user for the token if missing.
  ```bash
  kaggle datasets download -d olistbr/brazilian-ecommerce -p data/raw --unzip
  kaggle datasets download -d olistbr/marketing-funnel-olist -p data/raw --unzip
  ```
- Fallback: ask the user to download both zips manually and unzip into `data/raw/`.
- `data/raw/` is git-ignored. README explains how to download.

### 2.3 Files and expected row counts (approximate — record actuals; **warn** if any differs by >1%)

| File | Staging table | Expected rows | Columns |
|---|---|---|---|
| olist_orders_dataset.csv | stg_orders | ~99,441 | order_id, customer_id, order_status, order_purchase_timestamp, order_approved_at, order_delivered_carrier_date, order_delivered_customer_date, order_estimated_delivery_date |
| olist_order_items_dataset.csv | stg_order_items | ~112,650 | order_id, order_item_id, product_id, seller_id, shipping_limit_date, price, freight_value |
| olist_order_payments_dataset.csv | stg_order_payments | ~103,886 | order_id, payment_sequential, payment_type, payment_installments, payment_value |
| olist_order_reviews_dataset.csv | stg_order_reviews | ~99,224 | review_id, order_id, review_score, review_comment_title, review_comment_message, review_creation_date, review_answer_timestamp |
| olist_customers_dataset.csv | stg_customers | ~99,441 | customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state |
| olist_sellers_dataset.csv | stg_sellers | ~3,095 | seller_id, seller_zip_code_prefix, seller_city, seller_state |
| olist_products_dataset.csv | stg_products | ~32,951 | product_id, product_category_name, product_name_lenght, product_description_lenght, product_photos_qty, product_weight_g, product_length_cm, product_height_cm, product_width_cm |
| olist_geolocation_dataset.csv | stg_geolocation | ~1,000,163 | geolocation_zip_code_prefix, geolocation_lat, geolocation_lng, geolocation_city, geolocation_state |
| product_category_name_translation.csv | stg_category_translation | ~71 | product_category_name, product_category_name_english |
| olist_marketing_qualified_leads_dataset.csv | stg_mql | ~8,000 | mql_id, first_contact_date, landing_page_id, origin |
| olist_closed_deals_dataset.csv | stg_closed_deals | ~842 | mql_id, seller_id, sdr_id, sr_id, won_date, business_segment, lead_type, lead_behaviour_profile, has_company, has_gtin, average_stock, business_type, declared_product_catalog_size, declared_monthly_revenue |

Before writing load scripts: inspect each CSV header with `head -2`, detect line endings with `file`, and adapt (`LINES TERMINATED BY '\n'` vs `'\r\n'`). Headers may contain a UTF-8 BOM; `IGNORE 1 LINES` handles it.

### 2.4 Key grain facts (must be respected everywhere)
- `customer_id` is **per order**. The person is `customer_unique_id`. All customer-level analysis (repeat, cohorts, RFM) uses `customer_unique_id`.
- One order → many items (`order_item_id` 1..n), many payments (`payment_sequential` 1..n), usually one review (some exceptions).
- Joining items and payments directly on `order_id` causes **fan-out** (double counting). Always pre-aggregate one side first (demonstrated in a07).

---

## 3. Environment setup (macOS / Linux)

### 3.1 MySQL
- macOS: `brew install mysql@8.4 && brew services start mysql@8.4` (add to PATH as brew instructs). Linux (Ubuntu/Debian): `sudo apt install mysql-server`. Ask before installing.
- Verify: `SELECT VERSION();` must be **≥ 8.0.31** (INTERSECT/EXCEPT support). Stop and tell the user if lower.
- Server settings (in `my.cnf` or via `SET PERSIST` as root):
  - `local_infile = ON`
  - `cte_max_recursion_depth = 5000` (or set per session in scripts)
  - `log_bin_trust_function_creators = 1` (needed to create functions when binary logging is on)
  - keep default `sql_mode` (includes `ONLY_FULL_GROUP_BY`, `STRICT_TRANS_TABLES`) — **all queries must comply**.
- Database: `CREATE DATABASE olist CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;`
- Create app user `olist_user` with privileges on `olist.*` (password from user, stored in `.env`).
- CLI runs always use `mysql --local-infile=1`.

### 3.2 Python
- Python 3.11+, venv at `.venv/`.
- `requirements.txt` (pin major versions): `pandas`, `numpy`, `sqlalchemy>=2`, `pymysql`, `python-dotenv`, `scipy`, `statsmodels`, `matplotlib`, `jupyter`, `nbconvert`, `tabulate`, `kaggle`.
- No seaborn, no plotly. Charts use matplotlib only.

### 3.3 Config
- `.env` (git-ignored), `.env.example` (committed): `MYSQL_HOST=127.0.0.1`, `MYSQL_PORT=3306`, `MYSQL_USER=olist_user`, `MYSQL_PASSWORD=`, `MYSQL_DB=olist`.
- `.gitignore`: `.env`, `.venv/`, `data/raw/`, `powerbi/data/`, `__pycache__/`, `.ipynb_checkpoints/`, `*.pbix` is **committed** (not ignored) once the user builds it.

---

## 4. Repository structure (create exactly)

```
olist-marketplace-analytics/
├── README.md
├── PROJECT_SPEC.md                  (this file)
├── LICENSE                          (MIT for code; note data is CC BY-NC-SA 4.0)
├── Makefile
├── requirements.txt
├── .env.example
├── .gitignore
├── data/
│   └── raw/                         (git-ignored; CSVs land here)
├── sql/
│   ├── setup/
│   │   ├── 00_create_database.sql
│   │   ├── 01_staging_schema.sql
│   │   ├── 02_load_staging.sql
│   │   ├── 03_core_schema.sql
│   │   ├── 04_functions.sql
│   │   ├── 05_procedures.sql
│   │   ├── 06_transform_load_core.sql
│   │   ├── 07_data_quality_audit.sql
│   │   ├── 08_indexes_performance.sql
│   │   ├── 09_star_schema_views.sql
│   │   └── 10_marts.sql
│   └── analysis/
│       ├── a01_executive_kpis.sql
│       ├── ... (a01–a20, see §8)
│       └── a20_freight_economics.sql
├── python/
│   ├── db.py                        (SQLAlchemy engine from .env)
│   ├── load_fallback.py             (pandas loader if LOAD DATA fails)
│   ├── run_analysis.py              (runs analysis SQL, saves CSVs)
│   ├── export_powerbi.py            (exports star schema + marts to CSV)
│   ├── make_charts.py               (README charts)
│   └── fill_readme.py               (optional: replaces {{TBD}} from results)
├── notebooks/
│   └── 01_statistical_tests.ipynb
├── results/
│   ├── sql/                         (one CSV per @query, committed)
│   ├── stats/                       (stats_summary.md, test tables CSV)
│   └── charts/                      (PNG, committed)
├── powerbi/
│   ├── BUILD_GUIDE.md
│   ├── DAX_measures.md
│   ├── power_query_M.md
│   ├── theme.json
│   ├── data/                        (git-ignored exported CSVs)
│   ├── screenshots/                 (user adds PNGs after building)
│   └── olist_dashboard.pbix         (user adds after building)
└── docs/
    ├── data_dictionary.md
    ├── data_quality_log.md
    ├── metric_definitions.md
    ├── erd.md                        (Mermaid ER diagrams: core + star)
    ├── mysql_workarounds.md
    ├── performance.md
    ├── sql_concept_coverage.md
    ├── walkthrough.md                (plain-language explanation of every query)
    ├── recommendations.md
    └── interview_prep.md
```

---

## 5. Architecture (layers)

```
CSV (data/raw)
  └─► STAGING  stg_*   : all columns VARCHAR/TEXT, no constraints, loaded raw (LOAD DATA LOCAL INFILE)
        └─► CORE  core schema tables : typed, cleaned, PK/FK/NOT NULL/CHECK, quality flags
              ├─► STAR VIEWS  v_dim_*, v_fact_*      : analysis-friendly model (Power BI source)
              ├─► MARTS  mart_*  : summary tables = "materialized views" refreshed by sp_refresh_marts()
              └─► ANALYSIS  sql/analysis/a01–a20 → results/sql/*.csv
                      └─► PYTHON stats + charts → results/stats, results/charts
                              └─► POWER BI (CSV import) → dashboard
```

All objects live in database `olist`. Naming: staging `stg_`, core no prefix, views `v_`, marts `mart_`, functions `fn_`, procedures `sp_`, config `cfg_`.

---

## 6. Setup SQL files — exact requirements

Every SQL file starts with this header block:
```sql
/* ============================================================================
   File        : <name>
   Purpose     : <one line>
   Business Q  : <question it answers, or "setup">
   SQL concepts: <comma-separated list>
   Output      : <tables/columns created or returned>
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/...
   ========================================================================== */
```
Style: UPPERCASE keywords, snake_case identifiers, explicit `INNER JOIN`/`LEFT JOIN`, no `SELECT *` in analysis, meaningful aliases (`o`, `oi`, `p` acceptable only if defined in a comment), one CTE per logical step with descriptive names, comments on every non-obvious line, lines ≤ 110 chars.

### 6.0 `00_create_database.sql`
Create DB (utf8mb4 / utf8mb4_0900_ai_ci), `USE olist`, create `cfg_params`:
```sql
CREATE TABLE cfg_params (
  param_name  VARCHAR(50) PRIMARY KEY,
  param_value VARCHAR(50) NOT NULL,
  description VARCHAR(255)
);
-- rows:
-- ('window_start','2017-01-01','Analysis window start (edges of data are sparse)')
-- ('window_end','2018-08-31','Analysis window end')
-- ('repeat_horizon_days','180','Days after first order to count a repeat purchase')
-- ('low_review_max','2','Review score <= this is "low"')
-- ('min_orders_seller','30','Min delivered orders for seller-level ranking')
-- ('min_orders_lane','100','Min delivered orders for lane-level ranking')
```
All analysis reads these values from `cfg_params` (via CTE or user variables set at top of file) — never hard-code dates.

### 6.1 `01_staging_schema.sql`
`DROP TABLE IF EXISTS` + `CREATE TABLE stg_*` for all 11 files. Every column `VARCHAR(255)` except review title/message and long text → `TEXT`. No keys. Purpose: load never fails on dirty values.

### 6.2 `02_load_staging.sql`
`TRUNCATE` then `LOAD DATA LOCAL INFILE 'data/raw/<file>' INTO TABLE stg_<x> CHARACTER SET utf8mb4 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' LINES TERMINATED BY '\n' IGNORE 1 LINES (col1, col2, ...);`
- Use a path relative to repo root; Makefile runs from repo root.
- Review messages contain embedded newlines inside quotes — `OPTIONALLY ENCLOSED BY '"'` handles it. After load, print `SELECT 'stg_x', COUNT(*) FROM stg_x` for all tables.
- **Fallback**: if any count deviates >1% from §2.3 or LOAD DATA errors, run `python/load_fallback.py` (pandas `read_csv(dtype=str, keep_default_na=False)` → `to_sql(if_exists='append', chunksize=10000)` into the same staging tables). Document which path was used in `docs/data_quality_log.md`.

### 6.3 `03_core_schema.sql` — typed tables with constraints
Create in FK-safe order. Required definitions (add `COMMENT` on each table):

| Table | Columns (type) | Keys / constraints |
|---|---|---|
| `category_translation` | category_pt VARCHAR(80), category_en VARCHAR(80) | PK(category_pt) |
| `geolocation_zip` | zip_prefix CHAR(5), lat DECIMAL(9,6), lng DECIMAL(9,6), city VARCHAR(80), state CHAR(2), n_points INT | PK(zip_prefix); CHECK lat BETWEEN -34 AND 6; CHECK lng BETWEEN -74 AND -34 |
| `customers` | customer_id CHAR(32), customer_unique_id CHAR(32) NOT NULL, zip_prefix CHAR(5), city VARCHAR(80), city_clean VARCHAR(80), state CHAR(2) NOT NULL, region VARCHAR(15) | PK(customer_id); INDEX(customer_unique_id) |
| `sellers` | seller_id CHAR(32), zip_prefix CHAR(5), city VARCHAR(80), city_clean VARCHAR(80), state CHAR(2) NOT NULL, region VARCHAR(15) | PK(seller_id) |
| `products` | product_id CHAR(32), category_pt VARCHAR(80), category_en VARCHAR(80) NOT NULL, name_length INT, description_length INT, photos_qty INT, weight_g INT, length_cm INT, height_cm INT, width_cm INT | PK(product_id); CHECK weight_g >= 0 |
| `orders` | order_id CHAR(32), customer_id CHAR(32) NOT NULL, order_status VARCHAR(20) NOT NULL, purchase_ts DATETIME NOT NULL, approved_ts DATETIME, carrier_ts DATETIME, delivered_ts DATETIME, estimated_date DATE, delivery_days INT, delay_days INT, is_late TINYINT(1), ts_anomaly TINYINT(1) NOT NULL DEFAULT 0, is_valid_delivery TINYINT(1) NOT NULL DEFAULT 0 | PK(order_id); FK customer_id→customers; CHECK order_status IN ('delivered','shipped','canceled','unavailable','invoiced','processing','created','approved') |
| `order_items` | order_id CHAR(32), order_item_id INT, product_id CHAR(32) NOT NULL, seller_id CHAR(32) NOT NULL, shipping_limit_ts DATETIME, price DECIMAL(10,2) NOT NULL, freight_value DECIMAL(10,2) NOT NULL | PK(order_id, order_item_id); FKs → orders, products, sellers; CHECK price > 0; CHECK freight_value >= 0 |
| `order_payments` | order_id CHAR(32), payment_sequential INT, payment_type VARCHAR(20) NOT NULL, payment_installments INT NOT NULL, payment_value DECIMAL(10,2) NOT NULL | PK(order_id, payment_sequential); FK → orders; CHECK payment_value >= 0; CHECK payment_installments >= 1 |
| `order_reviews` | review_id CHAR(32), order_id CHAR(32), review_score TINYINT NOT NULL, has_comment TINYINT(1), review_created_date DATE, review_answer_ts DATETIME | PK(order_id) after dedup (one review per order — keep latest `review_answer_ts`); FK → orders; CHECK review_score BETWEEN 1 AND 5 |
| `seller_leads` | mql_id CHAR(32), first_contact_date DATE NOT NULL, landing_page_id CHAR(32), origin VARCHAR(30) NOT NULL, is_won TINYINT(1) NOT NULL, seller_id CHAR(32), won_date DATE, business_segment VARCHAR(60), lead_type VARCHAR(30), business_type VARCHAR(30), days_to_close INT | PK(mql_id); seller_id NOT FK-enforced (some won sellers never appear in orders) — explain in a comment |

Note: review text is not needed for analysis; keep only `has_comment` (1 if title or message non-empty).

### 6.4 `04_functions.sql` (use `DELIMITER $$`, all `DETERMINISTIC`, `NO SQL` or `READS SQL DATA` as appropriate)
1. `fn_delay_bucket(delay INT) RETURNS VARCHAR(20)`:
   NULL → 'Not delivered'; ≤ -7 → '1. Early 7+ d'; -6..0 → '2. On time'; 1..3 → '3. Late 1-3 d'; 4..7 → '4. Late 4-7 d'; > 7 → '5. Late 8+ d'. (Numeric prefixes keep sort order in Power BI.)
2. `fn_region(state CHAR(2)) RETURNS VARCHAR(15)`: North: AC AP AM PA RO RR TO; Northeast: AL BA CE MA PB PE PI RN SE; Center-West: DF GO MT MS; Southeast: ES MG RJ SP; South: PR RS SC; else 'Unknown'.
3. `fn_strip_accents(s VARCHAR(255)) RETURNS VARCHAR(255)`: LOWER + TRIM + nested `REPLACE` for á à â ã ä é è ê ë í ì î ï ó ò ô õ ö ú ù û ü ç ñ (and uppercase via LOWER first), collapse double spaces, also replace `'` and `-` with space then trim.
4. `fn_cfg(name VARCHAR(50)) RETURNS VARCHAR(50)` READS SQL DATA: returns `param_value` from `cfg_params`.

### 6.5 `05_procedures.sql`
1. `sp_load_core()` — wraps the whole staging→core transform in `START TRANSACTION ... COMMIT` with `DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;`. The body lives in `06_transform_load_core.sql` as the procedure definition (put the procedure there; 05 holds the other procedures). Demonstrates transactions + error handling.
2. `sp_refresh_marts()` — `TRUNCATE` + `INSERT ... SELECT` for every `mart_*` table, then `INSERT INTO mart_refresh_log(refreshed_at, mart_name, row_count)`. This is the MySQL replacement for materialized views.
3. `sp_seller_scorecard(IN p_seller_id CHAR(32))` — returns one seller's GMV, orders, on-time %, avg review, rank in category. Demonstrates parameterised procedures.

### 6.6 `06_transform_load_core.sql` — cleaning rules (implement every rule; log counts)
Create `dq_log(rule_id VARCHAR(10), table_name VARCHAR(40), description VARCHAR(255), rows_affected INT, logged_at DATETIME)` and insert a row for every rule below with `ROW_COUNT()` or a COUNT query.

| Rule | Issue | Treatment |
|---|---|---|
| R01 | Zip prefixes lost leading zeros (e.g. 1001) | `LPAD(TRIM(x),5,'0')` everywhere |
| R02 | Empty strings in date/number columns | `NULLIF(TRIM(x),'')` before `STR_TO_DATE(x,'%Y-%m-%d %H:%i:%s')` / CAST |
| R03 | Geolocation: many points per zip, some outside Brazil | Keep points with lat −34..6 and lng −74..−34; aggregate `AVG(lat), AVG(lng)`, mode city (via ROW_NUMBER on count), `COUNT(*) n_points` per zip |
| R04 | City names inconsistent (accents/case) | `city_clean = fn_strip_accents(city)` |
| R05 | Products: misspelled cols `product_name_lenght`, `product_description_lenght` | rename to `name_length`, `description_length` |
| R06 | Products with NULL/empty category | category_pt = 'sem_categoria', category_en = 'unknown' |
| R07 | Categories missing from translation table | `category_en = COALESCE(translation, category_pt)`; log which ones |
| R08 | Duplicate reviews per order / review_id reused across orders | One row per order: `ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY review_answer_ts DESC, review_created_date DESC) = 1` |
| R09 | Payments with `payment_type='not_defined'` | exclude; log count |
| R10 | `payment_installments = 0` | set to 1; log |
| R11 | Timestamp anomalies (approved < purchase, carrier < approved, delivered < carrier, delivered < purchase) | `ts_anomaly = 1`; keep row; exclude from SLA metrics |
| R12 | Status 'delivered' but delivered_ts NULL | `is_valid_delivery = 0`; log |
| R13 | Derived delivery fields | for `order_status='delivered' AND delivered_ts IS NOT NULL AND ts_anomaly=0`: `is_valid_delivery=1`, `delivery_days = DATEDIFF(DATE(delivered_ts), DATE(purchase_ts))`, `delay_days = DATEDIFF(DATE(delivered_ts), estimated_date)`, `is_late = (delay_days > 0)`; else NULLs |
| R14 | Leads: NULL origin | 'unknown' |
| R15 | Leads: derive is_won, days_to_close | `is_won = closed deal exists`; `days_to_close = DATEDIFF(won_date, first_contact_date)` |
| R16 | Items: non-positive price | exclude + log (expected 0) |
| R17 | Region | `region = fn_region(state)` for customers and sellers |

Order of load: category_translation → geolocation_zip → customers → sellers → products → orders → order_items → order_payments → order_reviews → seller_leads. Finish with `CALL sp_load_core();` pattern described in §6.5 (procedure created in this file, then called).

### 6.7 `07_data_quality_audit.sql` — one report via `UNION ALL`
Return a single result set `check_name, table_name, metric_value, expected, status ('PASS'/'WARN'/'FAIL')`. Checks:
- row counts per core table vs staging (after documented exclusions)
- PK uniqueness (COUNT vs COUNT DISTINCT) for every core table
- orphan FKs (items without order/product/seller; payments/reviews without order) via `LEFT JOIN ... IS NULL` → must be 0 (FAIL otherwise)
- % orders with `ts_anomaly`, % delivered without date (WARN thresholds 1%)
- reconciliation: SUM(price+freight) of non-canceled orders vs SUM(payment_value) of same orders (report gap %; WARN if > 2%)
- customers per customer_unique_id max (info)
- distinct order_status values not in CHECK list (must be 0)
`make quality` fails if any row is FAIL (Python wrapper checks).

### 6.8 `08_indexes_performance.sql`
1. Pick two slow queries (a04 lane SLA and a11 cohorts). Run `EXPLAIN ANALYZE` **before** adding secondary indexes; save output.
2. Create indexes: `orders(customer_id)`, `orders(purchase_ts)`, `orders(order_status, purchase_ts)`, `order_items(seller_id)`, `order_items(product_id)`, `customers(customer_unique_id)`, `order_payments(payment_type)`, `seller_leads(seller_id)`.
3. Re-run `EXPLAIN ANALYZE`; record before/after actual time and rows examined in `docs/performance.md` as a table.
4. SARGability demo: compare `WHERE YEAR(purchase_ts) = 2018` vs `WHERE purchase_ts >= '2018-01-01' AND purchase_ts < '2019-01-01'` with EXPLAIN; explain in comments why the second can use the index.

### 6.9 `09_star_schema_views.sql` — Power BI model source
- `dim_date` is a **table** (not a view) built with a **recursive CTE** from '2016-09-01' to '2018-12-31' (`SET SESSION cte_max_recursion_depth = 5000;`). Columns: date (PK), year, quarter, month_num, month_name, month_start, year_month ('2018-03'), week_start (Monday), day_of_week_num, day_name, is_weekend, in_window (between cfg window_start/end).
- `v_dim_customer`: one row per **customer_unique_id**: state, region, city_clean, first_order_ts, first_order_month, first_order_id, first_order_is_late, first_order_has_voucher, first_order_value, total_orders, total_gmv, eligible_repeat (first_order_ts ≤ window_end − repeat_horizon_days), repeat_180d (second order within horizon), rfm_segment (from a13 logic). Exclude canceled/unavailable orders from order counts.
- `v_dim_seller`: seller_id, state, region, city_clean, first_sale_month, last_sale_month, lead_origin (from seller_leads if won), is_acquired_via_funnel.
- `v_dim_product`: product_id, category_en, weight_g, volume_cm3 (= l×h×w), photos_qty.
- `v_fact_order_items` (**the single main fact; grain = order item**): order_id, order_item_id, purchase_date, customer_unique_id, seller_id, product_id, price, freight_value, item_gmv (= price + freight_value), order_status, is_valid_delivery, is_late, delivery_days, delay_days, delay_bucket (fn_delay_bucket), review_score, is_low_review, has_voucher (order-level), payment_type_main (type with largest value), max_installments, distance_km (seller zip ↔ customer zip via `ST_Distance_Sphere(POINT(lng,lat), POINT(lng,lat))/1000`), seller_region, customer_region. Filter: exclude order_status IN ('canceled','unavailable') and orders outside window.
  - Order-level attributes are intentionally **denormalised onto items** so one fact serves seller, product, customer and date slicing without bidirectional relationships. All order-level measures must use `DISTINCTCOUNT(order_id)` (see §11).
- `v_fact_seller_leads`: mql_id, first_contact_date, origin, landing_page_id, is_won, won_date, days_to_close, business_segment, lead_type, seller_id, first_sale_date, made_first_sale (1/0), gmv_first_90d, active_months_first_6.

### 6.10 `10_marts.sql`
Create tables + call `sp_refresh_marts()`:
- `mart_monthly_kpis` (year_month, gmv, orders, customers, aov, on_time_pct, low_review_pct, new_customers, gmv_mom_pct, gmv_yoy_pct)
- `mart_lane_sla` (seller_region, customer_region, seller_state, customer_state, delivered_orders, late_orders, late_pct, avg_delivery_days, median_delivery_days)
- `mart_cohort_retention` (cohort_month, months_since, active_customers, cohort_size, retention_pct) — long format
- `mart_seller_monthly` (seller_id, year_month, gmv, orders, is_active)
- `mart_pareto_sellers` (seller_id, gmv, gmv_rank, cum_gmv_share, seller_pct_rank)
- `mart_refresh_log`

---

## 7. Metric definitions (put verbatim in `docs/metric_definitions.md`; use consistently everywhere)

| Metric | Definition |
|---|---|
| Valid order | order_status NOT IN ('canceled','unavailable') and purchase_ts within window |
| GMV | SUM(price + freight_value) over items of valid orders (BRL; keep BRL, label "R$") |
| Merchandise value | SUM(price) |
| Orders | COUNT(DISTINCT order_id) of valid orders |
| AOV | GMV / Orders |
| Items per order | COUNT(items) / Orders |
| Freight share | SUM(freight) / GMV |
| Valid delivery | is_valid_delivery = 1 (delivered, has date, no anomaly) |
| Delivery days | DATEDIFF(delivered date, purchase date) |
| Delay days | DATEDIFF(delivered date, estimated date); > 0 = late |
| Late order | delay_days > 0 |
| On-time % | 1 − late orders / valid deliveries |
| Low review | review_score ≤ 2 |
| Low-review % | low-review orders / orders with a review |
| Customer | customer_unique_id |
| New customer (month) | customer whose first valid order is in that month |
| Repeat (180d) | customer with a second valid order within 180 days after first order |
| Repeat-eligible | first order on/before window_end − 180 days (avoids right-censoring bias) |
| Voucher first order | first order has ≥1 payment row with payment_type = 'voucher' |
| Active seller (month) | ≥1 item sold in that month |
| Seller churn episode | gap of ≥ 2 consecutive inactive months after being active |
| Lead conversion % | won leads / MQLs |
| Days to close | won_date − first_contact_date |
| Seller GMV 90d | GMV of seller's items in 90 days after first sale |
| MoM % / YoY % | (this − previous) / previous; YoY only where prior-year month exists |

---

## 8. Analysis SQL files (a01–a20)

### 8.1 Format rules
- Each file: header block (§6), then a `SET` block reading cfg params into user variables, e.g. `SET @ws = CAST(fn_cfg('window_start') AS DATE);`.
- Every result set is preceded by a marker line `-- @query: <snake_case_name>`; `python/run_analysis.py` splits on these markers and saves `results/sql/<file_stem>__<name>.csv`.
- Only `SET`, `SELECT` and `WITH` statements in analysis files (no DDL). Each must run standalone after setup.
- After each query, a comment block `-- Reading the result:` explaining how to interpret it (filled after running with actual top-line numbers).

### 8.2 The files

| File | Business question | Must demonstrate (SQL concepts) | Output (@query names) |
|---|---|---|---|
| **a01_executive_kpis** | How big and healthy is the marketplace? | CTEs, aggregates, COUNT DISTINCT, NULLIF, ROUND | `kpi_summary` (GMV, orders, customers, sellers, AOV, items/order, freight share, on-time %, avg delivery days, low-review %, repeat 180d %) |
| **a02_monthly_trends** | How is GMV growing MoM and YoY? | **Recursive CTE month spine**, LEFT JOIN to zero-fill, `DATE_FORMAT` month truncation, **LAG(1) and LAG(12)**, **3-month moving avg (ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)**, **running total (SUM OVER ORDER BY)** | `monthly_trend` |
| **a03_daily_spine_by_region** | What is the true average daily order count per region, counting zero days? | **Recursive date spine + CROSS JOIN** regions, LEFT JOIN, COALESCE, 7-day moving avg | `daily_orders_region`, `avg_daily_orders_region` |
| **a04_delivery_sla_by_lane** | Which seller→customer lanes break the delivery promise most? | multi-table INNER JOIN, GROUP BY + **HAVING** (min orders from cfg), conditional aggregation, **window-based median** (§13), **DENSE_RANK** by late orders | `lane_sla_state`, `lane_sla_region_matrix` (seller_region rows × customer_region columns via CASE pivot) |
| **a05_delay_vs_review** | How does lateness change review scores? | `fn_delay_bucket`, **CASE pivot** of score 1–5 shares per bucket, percentages with NULLIF | `review_by_delay_bucket` |
| **a06_worst_sellers_per_category** | Which sellers are dragging each category down? | **Correlated subquery** (seller late % > its category's avg), **DENSE_RANK PARTITION BY category**, top-3 per group via CTE filter (no QUALIFY in MySQL), HAVING min orders | `worst_sellers_top3`, `sellers_above_category_avg_count` |
| **a07_fanout_trap** | Why do naive joins overstate revenue? | Wrong query (items ⋈ payments) vs right (pre-aggregate payments per order in CTE); difference % | `gmv_naive_vs_correct` |
| **a08_items_vs_payments_reconciliation** | Do item totals match what customers paid? | **FULL OUTER JOIN emulation** (LEFT JOIN UNION RIGHT JOIN ... WHERE left IS NULL), CASE classification (match within R$0.01 / overpaid / underpaid / items-only / payments-only), ABS | `reconciliation_summary`, `reconciliation_examples` (LIMIT 20) |
| **a09_anti_and_semi_joins** | Which orders never got reviewed; which sellers went silent; which customers left a 5-star review? | **NOT EXISTS**, **LEFT JOIN … IS NULL**, **EXISTS** semi-join, **IN subquery**, scalar subquery for last date | `delivered_without_review`, `silent_sellers_90d`, `customers_with_5star` |
| **a10_set_operations** | Who bought in 2017 but not 2018? Which sellers were active in both H1-2017 and H1-2018? | **EXCEPT**, **INTERSECT**, **UNION vs UNION ALL** (show count difference), plus NOT EXISTS / INNER JOIN equivalents with matching counts | `lapsed_2017_customers`, `sellers_active_both_h1`, `union_vs_union_all` |
| **a11_cohort_retention** | Do customers come back month after month? | First-order month per customer_unique_id (MIN in CTE), PERIOD_DIFF for months_since, cohort size, **CASE pivot M0–M6**, retention % | `cohort_matrix`, `cohort_long` |
| **a12_repeat_and_time_to_second** | How fast do the few repeaters return, and who repeats? | **ROW_NUMBER** order sequence, **LEAD** next order date, DATEDIFF, **median & p25/p75 via ROW_NUMBER/COUNT and CUME_DIST**, repeat rate split by first-order late / on-time and by voucher / no-voucher (eligible cohort only) | `time_to_second_order_dist`, `repeat_by_first_order_late`, `repeat_by_first_order_voucher`, `customer_level_for_stats` (export full customer-level table for Python: customer_unique_id, first_late, first_voucher, first_value, region, first_category, repeat_180d) |
| **a13_rfm_segmentation** | Who are the most valuable customers? | **NTILE(5)** for R, F, M (F is mostly 1 — explain and use F as 1 vs 2+), CASE segment mapping, **FIRST_VALUE / LAST_VALUE** (with `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` — explain why LAST_VALUE needs it) for first & latest category | `rfm_segments_summary`, `customer_first_last_category` (LIMIT 50) |
| **a14_seller_gaps_islands** | How stable is seller supply? | month index per seller, **gaps-and-islands (month_idx − ROW_NUMBER)**, island length, gaps ≥ 2 months = churn episode, active sellers per month, monthly seller churn rate | `seller_streaks_summary`, `seller_churn_monthly` |
| **a15_order_status_funnel** | Where do orders get stuck between purchase and review? | Funnel stages: purchased → approved → handed to carrier → delivered → reviewed; counts, step & cumulative conversion, avg hours per stage (TIMESTAMPDIFF), by month via conditional aggregation | `order_funnel_overall`, `order_funnel_monthly`, `stage_durations` |
| **a16_seller_acquisition_funnel** | Which lead channels produce sellers who actually sell? | MQL → won → first sale → active 3+ of first 6 months; **LEFT JOIN chain**, GROUP BY origin, conversion %, median days to close, GMV 90d per won seller | `lead_funnel_by_origin`, `lead_funnel_overall`, `won_seller_value_by_origin` |
| **a17_pareto_concentration** | How dependent is GMV on a few sellers and categories? | **SUM() OVER (ORDER BY gmv DESC)** cumulative share, **PERCENT_RANK**, share of GMV from top 1%/10%/20% sellers | `pareto_sellers_summary`, `pareto_categories` |
| **a18_categories_and_strings** | Which categories and cities lead each state? | Translation join with **COALESCE**, string functions (LOWER, TRIM, SUBSTRING, CONCAT, REPLACE, `fn_strip_accents`), **ROW_NUMBER top-3 cities per state**, before/after count of distinct raw vs clean city names | `top_categories`, `top_cities_per_state`, `city_name_cleanup_effect` |
| **a19_basket_self_join** | Which categories are bought together? | **Self-join** of order_items on order_id with `a.category_en < b.category_en`, support, confidence, **lift**; HAVING min pair count 20 | `category_pairs` |
| **a20_freight_economics** | Is freight hurting conversion-sensitive categories and remote regions? | `ST_Distance_Sphere` distance bands (CASE), freight/price ratio, weight bands, **scalar subquery** vs overall average, GROUP BY ROLLUP (`WITH ROLLUP`) for subtotals | `freight_by_distance_band`, `freight_by_category`, `freight_rollup_region` |

### 8.3 Concept coverage (write `docs/sql_concept_coverage.md` as a table: concept → file(s))
Must list every item and its file: CREATE/ALTER/constraints (03), LOAD DATA (02), INSERT…SELECT/UPDATE/DELETE (06), transactions + rollback handler (06), stored functions (04), procedures incl. parameterised (05), views (09), "materialized views" via marts (10), indexes + EXPLAIN ANALYZE + SARGability (08), recursive CTE (09, a02, a03), chained CTEs, INNER/LEFT/RIGHT/FULL-emulated/SELF/CROSS joins, anti/semi joins, correlated/scalar/IN subqueries, UNION/UNION ALL/INTERSECT/EXCEPT, GROUP BY/HAVING/WITH ROLLUP, ROW_NUMBER/RANK/DENSE_RANK/NTILE/PERCENT_RANK/CUME_DIST, LAG/LEAD/FIRST_VALUE/LAST_VALUE, frames (ROWS BETWEEN), running totals, moving averages, CASE pivots, COALESCE/NULLIF, date functions (DATE_FORMAT, DATEDIFF, TIMESTAMPDIFF, PERIOD_DIFF, STR_TO_DATE, DATE_ADD), string functions, spatial (ST_Distance_Sphere), dedup, cohort, funnel, gaps-and-islands, Pareto, median/percentiles, MoM/YoY.
Also include one line: "Not covered by this dataset: sessionisation of clickstream (same LAG + running-SUM pattern as a14)."

---

## 9. Python

### 9.1 `python/db.py`
`get_engine()` → SQLAlchemy engine `mysql+pymysql://...` from `.env`, `pool_pre_ping=True`.

### 9.2 `python/run_analysis.py`
- Iterate `sql/analysis/a*.sql` in order. Strip comments safely, split into statements; execute `SET` statements; for each `-- @query: name` block, run the statement and save DataFrame to `results/sql/<file_stem>__<name>.csv`.
- Print a summary table (file, query, rows, seconds). Exit non-zero on any error.
- CLI: `python python/run_analysis.py [--only a04]`.

### 9.3 `notebooks/01_statistical_tests.ipynb`
Reads from MySQL (views/CSV from a12). Every test cell prints: hypothesis, unit of analysis, n per group, rates, difference with 95% CI, test statistic, p-value, effect size, plain-English conclusion, caveat. Alpha = 0.05, two-sided. Save `results/stats/stats_summary.md` and `results/stats/tests.csv`.

| # | Question | Unit | Method |
|---|---|---|---|
| T1 | Are late deliveries more likely to get low reviews? | valid delivered order with review | Two-proportion z-test (`statsmodels.stats.proportion.proportions_ztest`), CI for difference (`confint_proportions_2indep`, method='newcomb'), relative risk |
| T2 | Does review distribution differ across delay buckets? | same | Chi-square test of independence (`scipy.stats.chi2_contingency`) on bucket × score table, Cramér's V |
| T3 | Does a late **first** order reduce 180-day repeat? | repeat-eligible customer | Two-proportion z-test + CI; note low base rate |
| T4 | Do voucher-paid first orders repeat more? | repeat-eligible customer | Two-proportion z-test + CI; caveat: selection bias (voucher users differ) |
| T5 | Is the late-first-order effect robust to confounders? | repeat-eligible customer | Logistic regression (`statsmodels.formula.api.logit`): `repeat_180d ~ first_late + first_voucher + np.log(first_value) + C(region) + C(first_category_top10)` (other categories → 'other'), robust SE (`cov_type='HC1'`), report odds ratios + 95% CI. Note: review score is a mediator — deliberately excluded. |
| T6 | Is delivery time worse in North/Northeast? | valid delivery | Bootstrap 95% CI (2,000 resamples, seed 42) for median delivery days by customer region |
| T7 | How would we A/B test a "second-order voucher"? | design | Power analysis: baseline = observed repeat_180d rate; MDE = +20% relative; α=0.05, power=0.8 → n per arm (`proportion_effectsize` + `NormalIndPower().solve_power`); convert to weeks using avg monthly new customers; list guardrail metrics (AOV, margin proxy, low-review %) |

Charts saved to `results/charts/` (matplotlib, 150 dpi, titled, axis-labelled, R$ formatting where money): `01_monthly_gmv.png` (bars + 3M MA line), `02_review_by_delay.png` (100% stacked bars), `03_cohort_heatmap.png` (M0–M6), `04_repeat_late_vs_ontime_ci.png` (bars with CI error bars), `05_lead_funnel.png`, `06_pareto_sellers.png`, `07_lane_late_heatmap.png`.

### 9.4 `python/export_powerbi.py`
Export to `powerbi/data/` as UTF-8 CSV (comma, header, ISO dates `YYYY-MM-DD`, decimals with `.`): `dim_date`, `dim_customer`, `dim_seller`, `dim_product`, `fact_order_items`, `fact_seller_leads`, `mart_cohort_retention`, `mart_pareto_sellers`, `mart_lane_sla`. Print row counts. Also write `powerbi/data/_manifest.csv` (file, rows, columns).

---

## 10. Makefile targets

```
make venv         # create .venv, pip install -r requirements.txt
make download     # kaggle downloads into data/raw
make db           # 00 + 01 (create db, staging)
make load         # 02 (LOAD DATA; on failure suggest `make load-fallback`)
make load-fallback# python/load_fallback.py
make core         # 03 04 05 06
make quality      # 07 + python check: fail on any FAIL row
make perf         # 08
make model        # 09 10
make analysis     # python/run_analysis.py
make stats        # jupyter nbconvert --execute --to notebook --inplace notebooks/01_statistical_tests.ipynb
make charts       # python/make_charts.py (if not produced in notebook)
make export       # python/export_powerbi.py
make all          # db load core quality perf model analysis stats export
make clean-db     # DROP DATABASE olist (ask for confirmation in the recipe)
```
`make all` from an empty MySQL must complete with zero errors. MySQL credentials passed via `--defaults-extra-file` generated from `.env` at runtime (temp file, chmod 600, deleted after) — never echo the password.

---

## 11. Power BI kit (`powerbi/`)

### 11.1 Model (document in BUILD_GUIDE with a diagram)
- Tables: `dim_date`, `dim_customer`, `dim_seller`, `dim_product`, `fact_order_items`, `fact_seller_leads`, `mart_cohort_retention`, `mart_pareto_sellers`, `mart_lane_sla`.
- Relationships (all single-direction, many-to-one, active):
  - `fact_order_items[purchase_date]` → `dim_date[date]`
  - `fact_order_items[customer_unique_id]` → `dim_customer[customer_unique_id]`
  - `fact_order_items[seller_id]` → `dim_seller[seller_id]`
  - `fact_order_items[product_id]` → `dim_product[product_id]`
  - `fact_seller_leads` and marts: no relationships (standalone visuals with own slicers). Explain why (different grain; avoids ambiguous paths).
- Mark `dim_date` as date table. Sort `month_name` by `month_num`; `delay_bucket` sorts by its numeric prefix.
- Hide all ID/key columns from report view; set formats (R$ #,##0; 0.0%).

### 11.2 `power_query_M.md`
- Parameter `DataFolder` (text path to `powerbi/data/`).
- For each CSV: full M script: `Csv.Document(File.Contents(DataFolder & "\\fact_order_items.csv"), [Delimiter=",", Encoding=65001, QuoteStyle=QuoteStyle.Csv])`, `Table.PromoteHeaders`, explicit `Table.TransformColumnTypes` with **every column typed** using locale "en-US" (generate from the actual export schema — do not guess), plus a step renaming nothing (names already clean).
- One "Applied steps" explanation per table.

### 11.3 `DAX_measures.md` — create a `_Measures` table; include exactly these (code + one-line meaning + format)
```DAX
GMV = SUM ( fact_order_items[item_gmv] )
Merchandise Value = SUM ( fact_order_items[price] )
Orders = DISTINCTCOUNT ( fact_order_items[order_id] )
AOV = DIVIDE ( [GMV], [Orders] )
Customers = DISTINCTCOUNT ( fact_order_items[customer_unique_id] )
Active Sellers = DISTINCTCOUNT ( fact_order_items[seller_id] )
Freight Share = DIVIDE ( SUM ( fact_order_items[freight_value] ), [GMV] )

Valid Deliveries =
CALCULATE ( [Orders], fact_order_items[is_valid_delivery] = 1 )
Late Orders =
CALCULATE ( [Orders], fact_order_items[is_valid_delivery] = 1, fact_order_items[is_late] = 1 )
On-time % = DIVIDE ( [Valid Deliveries] - [Late Orders], [Valid Deliveries] )

-- order-weighted (not item-weighted) average: one value per order
Avg Delivery Days =
AVERAGEX (
    CALCULATETABLE ( VALUES ( fact_order_items[order_id] ), fact_order_items[is_valid_delivery] = 1 ),
    CALCULATE ( MAX ( fact_order_items[delivery_days] ) )
)

Reviewed Orders =
CALCULATE ( [Orders], NOT ISBLANK ( fact_order_items[review_score] ) )
Low Review Orders =
CALCULATE ( [Orders], fact_order_items[is_low_review] = 1 )
Low Review % = DIVIDE ( [Low Review Orders], [Reviewed Orders] )

GMV PM = CALCULATE ( [GMV], DATEADD ( dim_date[date], -1, MONTH ) )
GMV MoM % = DIVIDE ( [GMV] - [GMV PM], [GMV PM] )
GMV PY = CALCULATE ( [GMV], SAMEPERIODLASTYEAR ( dim_date[date] ) )
GMV YoY % = IF ( NOT ISBLANK ( [GMV PY] ), DIVIDE ( [GMV] - [GMV PY], [GMV PY] ) )
GMV 3M Avg =
DIVIDE (
    CALCULATE ( [GMV], DATESINPERIOD ( dim_date[date], MAX ( dim_date[date] ), -3, MONTH ) ),
    3
)

Eligible Customers =
CALCULATE ( COUNTROWS ( dim_customer ), dim_customer[eligible_repeat] = 1 )
Repeat Customers 180d =
CALCULATE ( COUNTROWS ( dim_customer ), dim_customer[eligible_repeat] = 1, dim_customer[repeat_180d] = 1 )
Repeat Rate 180d = DIVIDE ( [Repeat Customers 180d], [Eligible Customers] )

Seller Late Rank =
RANKX ( ALLSELECTED ( dim_seller[seller_id] ), [Late Orders], , DESC, DENSE )
Show In Top N = IF ( [Seller Late Rank] <= 'Top N'[Top N Value], 1, 0 )

MQLs = COUNTROWS ( fact_seller_leads )
Won Leads = CALCULATE ( COUNTROWS ( fact_seller_leads ), fact_seller_leads[is_won] = 1 )
Lead Conversion % = DIVIDE ( [Won Leads], [MQLs] )
Sellers With First Sale =
CALCULATE ( COUNTROWS ( fact_seller_leads ), fact_seller_leads[made_first_sale] = 1 )
GMV 90d per Won Seller =
DIVIDE ( SUM ( fact_seller_leads[gmv_first_90d] ), [Won Leads] )
```
`Top N` = What-if parameter (5–25, default 10). Explain in BUILD_GUIDE that `Customers` counts customers who bought in the filter context, while repeat measures come from `dim_customer` (cohort-based).

### 11.4 Report pages (exact layout spec in BUILD_GUIDE; 16:9, 1280×720)
**Page 1 — Marketplace Ops Overview**
- Top row KPI cards: GMV, Orders, AOV, On-time %, Avg Delivery Days, Low Review %, Repeat Rate 180d.
- Combo chart: GMV by `dim_date[year_month]` (columns) + GMV 3M Avg (line); tooltip MoM %, YoY %.
- Matrix: rows `dim_seller[region]`, columns `dim_customer[region]`, value On-time % with conditional formatting (red low → green high) — the lane heatmap.
- Table: Top-N worst sellers (seller_id short code, category via tooltip, Orders, Late Orders, On-time %, Low Review %), visual filter `Show In Top N = 1`.
- Clustered bar: Low Review % by `delay_bucket`.
- Slicers (left panel): date range (dim_date[date]), category (dim_product[category_en]), customer state, payment_type_main.

**Page 2 — Customers & Seller Supply**
- Matrix: `mart_cohort_retention` cohort_month × months_since, value retention_pct, conditional formatting.
- Clustered column: Repeat Rate 180d by `dim_customer[first_order_is_late]` and by `first_order_has_voucher` (two visuals side by side) with data labels.
- Funnel chart: MQLs → Won Leads → Sellers With First Sale (from fact_seller_leads), slicer on origin.
- Bar: Lead Conversion % and GMV 90d per Won Seller by origin.
- Line/area: Pareto curve from `mart_pareto_sellers` (x = seller_pct_rank, y = cum_gmv_share) with a constant line at 80%.
- Text box: 3 key findings (fill from results — no invented numbers).

### 11.5 `theme.json`
Minimal valid Power BI theme: name "Olist Ops"; dataColors `["#1F4E79","#2E86AB","#F18F01","#C73E1D","#3B8B5A","#6C757D","#A23B72","#99C24D"]`; background "#FFFFFF"; foreground "#1A1A1A"; tableAccent "#1F4E79"; good/neutral/bad `#3B8B5A/#F18F01/#C73E1D`. Validate JSON.

### 11.6 `BUILD_GUIDE.md` — click-by-click
Sections: prerequisites; copy `powerbi/data/` to the Windows machine; Get Data → Text/CSV via the M scripts (Advanced Editor paste); set `DataFolder`; model view relationships (with screenshot placeholders); mark date table; create `_Measures` (Enter data → empty table) and paste measures; What-if parameter; build Page 1 and Page 2 visual by visual (field wells listed exactly); apply theme; formatting checklist (titles, consistent R$ and % formats, no default "Sum of"); performance analyzer check; save `olist_dashboard.pbix` into `powerbi/`; export PDF of both pages into `powerbi/`; screenshots into `powerbi/screenshots/`; publish (§11.7). Estimated time: 3–4 hours.

### 11.7 Platform & publishing notes (put in BUILD_GUIDE)
- Power BI Desktop runs on Windows only. Options: any Windows PC (college lab/friend) using the exported CSVs, or a Windows VM on Mac (Parallels/VMware) — test install early.
- Publishing: Power BI Service "Publish to web" requires a work/school account whose tenant allows it. If unavailable: upload to NovyPro (novypro.com) and embed the link; always keep PDF export + screenshots + a 60-second GIF in README.

---

## 12. Documentation files

- `docs/data_dictionary.md`: every core table and star view; column, type, meaning, example value.
- `docs/data_quality_log.md`: table of R01–R17 with actual counts from `dq_log`, plus audit results from 07 and which load path was used.
- `docs/erd.md`: two Mermaid `erDiagram` blocks — (1) core normalised schema with PK/FK, (2) star schema. GitHub renders Mermaid.
- `docs/mysql_workarounds.md`: the §13 table, each with a short code snippet and the file where it's used.
- `docs/performance.md`: before/after EXPLAIN ANALYZE table + SARGability note.
- `docs/walkthrough.md`: for each of a01–a20, 5–8 lines: what it answers, logic step-by-step in plain English, the trickiest line and why, how to explain it in 60 seconds in an interview.
- `docs/recommendations.md`: §14.
- `docs/interview_prep.md`: §15.

---

## 13. MySQL workarounds (implement + document)

| Postgres/other feature | MySQL 8 approach used | Where |
|---|---|---|
| FULL OUTER JOIN | `LEFT JOIN ... UNION ALL ... RIGHT JOIN ... WHERE left.key IS NULL` | a08 |
| PERCENTILE_CONT / MEDIAN | `ROW_NUMBER()` + `COUNT() OVER` per group; median = AVG of rows where rn IN (FLOOR((n+1)/2), CEIL((n+1)/2)); percentiles via `CUME_DIST()` first row ≥ p | a04, a12, marts |
| MATERIALIZED VIEW | summary `mart_*` tables + `sp_refresh_marts()` + `mart_refresh_log` | 05, 10 |
| generate_series | recursive CTE + `SET SESSION cte_max_recursion_depth` | 09, a02, a03 |
| DATE_TRUNC('month') | `DATE_FORMAT(ts,'%Y-%m-01')` cast to DATE; `PERIOD_DIFF(DATE_FORMAT(a,'%Y%m'), DATE_FORMAT(b,'%Y%m'))` for month offsets | a02, a11 |
| FILTER (WHERE …) aggregates | `SUM(CASE WHEN … THEN 1 ELSE 0 END)` | many |
| QUALIFY | wrap window in CTE, filter outside | a06, a18 |
| DISTINCT ON | `ROW_NUMBER() ... = 1` | 06 (R08), a18 |
| ILIKE / unaccent | `utf8mb4_0900_ai_ci` collation + `fn_strip_accents` | 04, a18 |
| STRING_AGG | `GROUP_CONCAT(... ORDER BY ... SEPARATOR ', ')` with `SET SESSION group_concat_max_len = 100000` | a16 (sample landing pages) |
| BOOLEAN | `TINYINT(1)` | 03 |
| INTERSECT / EXCEPT | native (8.0.31+) and equivalent NOT EXISTS / INNER JOIN versions shown | a10 |
| Haversine function | `ST_Distance_Sphere(POINT(lng,lat), POINT(lng,lat))` | 09, a20 |

---

## 14. Recommendations (`docs/recommendations.md`) — fill with real numbers only
Produce 4–5 recommendations. Each has: finding (with number + source file), action, owner, **estimated impact with explicit formula and assumptions**, how to validate (metric + experiment). Candidate set (keep only those the data supports):
1. **Fix the worst lanes first** — impact ≈ late orders in top-10 lanes × (low-review rate late − on-time) and × (repeat-rate gap late vs on-time) × AOV.
2. **Re-calibrate estimated delivery dates on chronically late lanes** (promise accuracy) — validate with an A/B test on promise padding; guardrail: conversion proxy.
3. **Seller quality programme** for sellers above their category's late average (a06) — impact via their share of late orders.
4. **Second-order voucher test** designed with T7 sample size — expected incremental repeat customers = eligible new customers × MDE.
5. **Shift seller-acquisition spend** toward lead origins with highest GMV 90d per won seller (a16).
Add a "What I would do with more data" section (margin/commission data, marketing cost for CAC, clickstream for sessionisation).

---

## 15. Interview prep (`docs/interview_prep.md`)
Generate, using real numbers:
- 60-second project pitch (problem → data → method → 3 findings → recommendation).
- 3 resume bullets (action verb + tool + quantified result), e.g. template: "Built an end-to-end MySQL analytics pipeline (staging → constrained core → star schema, 20 analytical modules) on ~100k orders / 1.5M+ rows; showed late deliveries raise low-review rate from {{a}}% to {{b}}% (z-test, p<{{p}})". Replace all placeholders with actuals.
- 25 likely questions with model answers covering: grain & customer_unique_id trap; fan-out; FULL OUTER JOIN in MySQL; median in MySQL; why staging tables; transactions; indexes and SARGability; recursive CTE; gaps-and-islands logic; cohort right-censoring and the 180-day eligibility rule; why a z-test (and not a t-test); chi-square vs z-test; correlation vs causation in T3/T4 and how T5 helps; mediator exclusion; A/B test design + MDE + guardrails; Power BI star schema and single-direction filters; why order-weighted avg delivery; DAX DIVIDE vs "/"; materialized-view emulation; data-quality decisions; biggest limitation; what you'd do next; how this applies to Meesho/Flipkart (RTO, delivery promise) and to a consulting client.
- "Explain this query in 60 seconds" cards for a04, a07, a08, a11, a12, a14.

---

## 16. Build phases, gates and commits

| Phase | Work | Gate (must pass) | Commit message |
|---|---|---|---|
| 0 | Repo skeleton, .gitignore, .env.example, requirements, Makefile, README stub, `git init` | `make venv` succeeds | `chore: project skeleton` |
| 1 | MySQL check/setup, download data | VERSION ≥ 8.0.31; all 11 CSVs present | `chore: environment and data download` |
| 2 | 00, 01, 02 staging load | staging counts within 1% of §2.3 (or fallback used & logged) | `feat(sql): staging schema and raw load` |
| 3 | 03, 04, 05, 06 core + functions + procedures + transform | `sp_load_core` runs in a transaction; dq_log populated | `feat(sql): typed core schema, functions, procedures, cleaning` |
| 4 | 07 quality audit | zero FAIL rows | `feat(sql): data quality audit` |
| 5 | 08 performance | before/after table in docs/performance.md | `perf(sql): indexes and EXPLAIN ANALYZE` |
| 6 | 09, 10 star + marts | views query fine; `sp_refresh_marts` logs row counts; GMV in mart_monthly_kpis sums to GMV from fact view (exact match) | `feat(sql): star schema views and marts` |
| 7 | a01–a20 + run_analysis.py | `make analysis` exits 0; every @query CSV non-empty | `feat(sql): analysis modules a01-a20` |
| 8 | Stats notebook + charts | notebook executes top-to-bottom headless; stats_summary.md + 7 charts exist | `feat(stats): hypothesis tests, regression, power analysis` |
| 9 | Power BI kit + export | export manifest written; theme.json valid JSON; every DAX measure references existing columns | `feat(powerbi): export and build kit` |
| 10 | Docs (all §12), README, recommendations, interview prep | no `{{TBD}}` left except dashboard link/screenshots; every number traceable to results/ | `docs: README, findings, recommendations, interview prep` |
| 11 | Final check: `make clean-db && make all` from scratch | zero errors end-to-end | `chore: verified clean rebuild` |

---

## 17. README.md (recruiter-facing; this order)
1. Title + one-line pitch + badges (MySQL 8, Python, Power BI).
2. **TL;DR — 3 headline findings with numbers** + 1 recommendation (from results).
3. Dashboard: screenshot(s) + live link (placeholder until user publishes) + PDF link.
4. Business problem & stakeholder (§1).
5. Data: sources, size table (actual row counts), license/attribution.
6. Architecture diagram (Mermaid flowchart of §5) + ERD link.
7. Data cleaning: short table of top issues and fixes (link to data_quality_log).
8. Analysis modules: table a01–a20 (question → key result, one line each).
9. Statistics: T1–T7 summary table (n, effect, CI, p, conclusion).
10. Key findings (5–7 bullets, each with number and link to the CSV/chart).
11. Recommendations with impact (link to docs/recommendations.md).
12. SQL concept coverage (link) + MySQL workarounds (link).
13. How to reproduce (`make venv download all`, Power BI build guide).
14. Limitations & next steps.
15. Repo structure tree.
16. Author: Nandhagopan Nair — IIT (BHU) Varanasi — LinkedIn/GitHub placeholders.
Keep README scannable: first screen must show pitch, TL;DR and dashboard image.

---

## 18. Definition of done (final checklist)
- [ ] `make clean-db && make all` succeeds from an empty server.
- [ ] Every SQL file has the header block and per-query "Reading the result" comments with real numbers.
- [ ] All 20 analysis modules produce non-empty CSVs in `results/sql/`.
- [ ] Data quality audit: zero FAIL; all WARNs explained in data_quality_log.md.
- [ ] performance.md has before/after timings.
- [ ] Notebook runs headless; 7 charts present; stats_summary.md complete with CIs and caveats.
- [ ] Power BI kit complete; BUILD_GUIDE is click-by-click; DAX and M validated against exported columns.
- [ ] README first screen: pitch, 3 numeric findings, dashboard image.
- [ ] sql_concept_coverage.md lists every concept with file references.
- [ ] interview_prep.md: pitch, 3 resume bullets with real numbers, 25 Q&As, 6 query cards.
- [ ] No secrets in git history; `.env` ignored; raw data ignored.
- [ ] No invented numbers anywhere.
