# MySQL 8 workarounds

MySQL 8.4 lacks several features that PostgreSQL or Snowflake users take for granted. Each row shows the substitute
used in this repo and where to find it.

| Postgres / other feature | MySQL 8 approach used | Where |
|---|---|---|
| FULL OUTER JOIN | `LEFT JOIN … UNION ALL … RIGHT JOIN … WHERE left.key IS NULL` | a08 |
| PERCENTILE_CONT / MEDIAN | `ROW_NUMBER()` + `COUNT() OVER` per group; median = AVG of rows where rn IN (FLOOR((n+1)/2), CEIL((n+1)/2)); percentiles via `CUME_DIST()` first row ≥ p | a04, a12, a15, a16, 05 (marts) |
| MATERIALIZED VIEW | summary `mart_*` tables + `sp_refresh_marts()` + `mart_refresh_log` | 05, 10 |
| generate_series | recursive CTE + `SET SESSION cte_max_recursion_depth` | 09, a02, a03, a14, 05 |
| DATE_TRUNC('month') | `DATE_FORMAT(ts,'%Y-%m-01')` cast to DATE; `PERIOD_DIFF(DATE_FORMAT(a,'%Y%m'), DATE_FORMAT(b,'%Y%m'))` for month offsets | a02, a11, a14, a16 |
| FILTER (WHERE …) aggregates | `SUM(CASE WHEN … THEN 1 ELSE 0 END)` | many (a01, a04, a05, 07 …) |
| QUALIFY | wrap the window function in a CTE, filter outside | a06, a18 |
| DISTINCT ON | `ROW_NUMBER() … = 1` | 06 (R08), a12, a18 |
| ILIKE / unaccent | `utf8mb4_0900_ai_ci` collation + `fn_strip_accents` | 00, 04, a18 |
| STRING_AGG | `GROUP_CONCAT(… ORDER BY … SEPARATOR ', ')` with `SET SESSION group_concat_max_len = 100000` | a16 (top landing pages), 06 (R07 list) |
| BOOLEAN | `BOOLEAN` keyword = `TINYINT(1)` | 03, 09, 10 |
| INTERSECT / EXCEPT | native (8.0.31+) and equivalent NOT EXISTS / INNER JOIN versions shown | a10 |
| Haversine function | `ST_Distance_Sphere(POINT(lng,lat), POINT(lng,lat))` | 09, a20 |
| CREATE INDEX IF NOT EXISTS / DROP INDEX IF EXISTS | check `information_schema.statistics`, run DDL with `PREPARE`/`EXECUTE` | 08 |

## Snippets

**FULL OUTER JOIN** (a08)
```sql
SELECT i.order_id, i.items_total, p.paid_total
FROM items_by_order AS i LEFT JOIN payments_by_order AS p ON p.order_id = i.order_id
UNION ALL
SELECT p.order_id, NULL, p.paid_total
FROM items_by_order AS i RIGHT JOIN payments_by_order AS p ON p.order_id = i.order_id
WHERE i.order_id IS NULL;           -- only rows the LEFT JOIN could not produce -> no duplicates
```

**Median per group** (a04)
```sql
WITH ranked AS (
  SELECT lane, delivery_days,
         ROW_NUMBER() OVER (PARTITION BY lane ORDER BY delivery_days) AS rn,
         COUNT(*)     OVER (PARTITION BY lane)                        AS n
  FROM order_lanes)
SELECT lane, AVG(CASE WHEN rn IN (FLOOR((n + 1) / 2), CEIL((n + 1) / 2)) THEN delivery_days END) AS median_days
FROM ranked GROUP BY lane;          -- odd n: one middle row; even n: average of the two middle rows
```

**Percentile via CUME_DIST** (a12)
```sql
SELECT MIN(CASE WHEN cume >= 0.25 THEN days_to_second END) AS p25_days
FROM (SELECT days_to_second, CUME_DIST() OVER (ORDER BY days_to_second) AS cume FROM returners) AS d;
```

**Materialized view** (05 / 10)
```sql
TRUNCATE TABLE mart_lane_sla;
INSERT INTO mart_lane_sla (...) WITH ... SELECT ...;
INSERT INTO mart_refresh_log (refreshed_at, mart_name, row_count) VALUES (v_run_ts, 'mart_lane_sla', ROW_COUNT());
-- CALL sp_refresh_marts();  = REFRESH MATERIALIZED VIEW for all marts
```

**generate_series** (a02)
```sql
SET SESSION cte_max_recursion_depth = 5000;
WITH RECURSIVE month_spine (month_start) AS (
  SELECT CAST(DATE_FORMAT(@ws, '%Y-%m-01') AS DATE)
  UNION ALL
  SELECT month_start + INTERVAL 1 MONTH FROM month_spine WHERE month_start + INTERVAL 1 MONTH <= @we)
SELECT month_start FROM month_spine;
```

**DATE_TRUNC / month offset** (a11)
```sql
CAST(DATE_FORMAT(o.purchase_ts, '%Y-%m-01') AS DATE)               -- DATE_TRUNC('month', ts)
PERIOD_DIFF(DATE_FORMAT(o.purchase_ts, '%Y%m'), cohort_ym)          -- months between two months
```

**FILTER (WHERE)** (a05)
```sql
SUM(CASE WHEN review_score = 5 THEN 1 ELSE 0 END)                   -- COUNT(*) FILTER (WHERE review_score = 5)
```

**QUALIFY** (a18)
```sql
WITH ranked AS (SELECT state, city_clean, orders,
                       ROW_NUMBER() OVER (PARTITION BY state ORDER BY orders DESC) AS city_rank
                FROM city_orders)
SELECT * FROM ranked WHERE city_rank <= 3;                           -- QUALIFY city_rank <= 3
```

**DISTINCT ON** (06, rule R08)
```sql
SELECT ... FROM (SELECT r.*, ROW_NUMBER() OVER (PARTITION BY order_id
                 ORDER BY review_answer_ts DESC, review_created_date DESC, review_id DESC) AS rn
                 FROM typed AS r) AS x
WHERE rn = 1;                                                        -- DISTINCT ON (order_id) ... ORDER BY ...
```

**ILIKE / unaccent** (00, 04, a18)
```sql
-- utf8mb4_0900_ai_ci: 'São Paulo' = 'sao paulo' is TRUE (accent- and case-insensitive)
-- exact comparison when needed: city COLLATE utf8mb4_bin <> city_clean COLLATE utf8mb4_bin
SELECT fn_strip_accents('  São-Paulo  D''Oeste ');                   -- 'sao paulo d oeste'
```

**STRING_AGG** (a16)
```sql
SET SESSION group_concat_max_len = 100000;
GROUP_CONCAT(CONCAT(LEFT(landing_page_id, 8), ' (', n_leads, ')') ORDER BY n_leads DESC SEPARATOR ', ')
```

**INTERSECT / EXCEPT** (a10)
```sql
SELECT COUNT(*) FROM (SELECT customer_unique_id FROM buyers_2017
                      EXCEPT SELECT customer_unique_id FROM buyers_2018) AS lapsed;      -- native, 8.0.31+
SELECT COUNT(*) FROM buyers_2017 AS b17
WHERE NOT EXISTS (SELECT 1 FROM buyers_2018 AS b18 WHERE b18.customer_unique_id = b17.customer_unique_id);
```

**Haversine** (09, a20)
```sql
ST_Distance_Sphere(POINT(sg.lng, sg.lat), POINT(cg.lng, cg.lat)) / 1000 AS distance_km   -- POINT(x = lng, y = lat)
```

## MySQL-specific gotchas hit while building (good interview material)

| Gotcha | Symptom | Fix (file) |
|---|---|---|
| `ROW_NUMBER()` returns **BIGINT UNSIGNED** | `month_idx - ROW_NUMBER()` raised "BIGINT UNSIGNED value is out of range" when the result went negative | `CAST(ROW_NUMBER() OVER (...) AS SIGNED)` (a14) |
| `COUNT(DISTINCT …) OVER (…)` | error 1235 "not supported" | count in a separate grouped CTE (a13) |
| `first_value`, `year_month` are reserved words | syntax error on an alias / column | backticks: `` `first_value` `` (a12), `` `year_month` `` (09, 10, a02) |
| `TRUNCATE` inside a transaction | implicitly COMMITs, so a rollback can't undo it | `DELETE FROM` inside `sp_load_core` (06) |
| `TINYINT(1)` | "integer display width is deprecated" warning in 8.4 | declare as `BOOLEAN` (stored as tinyint(1)) (03) |
| Client character set | accented literals in function bodies arrived as latin1 (`s�o`) | `default-character-set=utf8mb4` in the generated option file + `SET NAMES utf8mb4` (Makefile, 04) |
| `LOAD DATA` default `ESCAPED BY '\\'` | a review ending in `\"` would shift columns | `ESCAPED BY ''` (02) |
| `LINES TERMINATED BY '\n'` on a Windows file | invisible `\r` glued to the last column | `'\r\n'` for the two CRLF files (02) |
| `%` in SQL sent through PyMySQL | `DATE_FORMAT(x, '%Y')` read as a Python format placeholder | `execution_options={"no_parameters": True}` (python/run_analysis.py) |
| Implicit FK indexes | creating `idx_orders_customer_id` silently dropped `fk_orders_customer` | expected InnoDB behaviour, documented (08, performance.md) |
