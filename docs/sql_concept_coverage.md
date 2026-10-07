# SQL concept coverage

Where each concept is demonstrated. Setup files are `sql/setup/NN_*.sql`; analysis files are `sql/analysis/aNN_*.sql`.

| Concept | File(s) | Example in that file |
|---|---|---|
| CREATE TABLE, data types, table/column COMMENT | 00, 01, 03, 06, 09, 10 | typed core tables (03) |
| ALTER TABLE | 08 | `ALTER TABLE … ADD INDEX / DROP INDEX` via dynamic SQL |
| Constraints: PRIMARY KEY (single + composite), FOREIGN KEY, NOT NULL, DEFAULT, CHECK | 03 | `chk_orders_status`, `chk_items_price`, PK(order_id, order_item_id) |
| BOOLEAN (= TINYINT(1)) | 03, 09, 10 | `is_late`, `is_valid_delivery` |
| LOAD DATA LOCAL INFILE (CSV options, CRLF, escaping) | 02 | `ESCAPED BY ''`, `LINES TERMINATED BY '\r\n'` |
| INSERT … VALUES / INSERT … SELECT / INSERT … WITH | 00, 06, 09, 05 | geolocation centroid insert (06) |
| UPDATE | 06 | R11 `ts_anomaly`, R13 derived delivery fields |
| DELETE | 06 | R09 `not_defined` payments; emptying core inside the transaction |
| Transactions + rollback handler | 06 | `START TRANSACTION … COMMIT`, `DECLARE EXIT HANDLER FOR SQLEXCEPTION … ROLLBACK; RESIGNAL` |
| ROW_COUNT() logging | 06, 05 | `dq_log`, `mart_refresh_log` |
| Stored functions (DETERMINISTIC, NO SQL / READS SQL DATA, loops) | 04 | `fn_delay_bucket`, `fn_region`, `fn_strip_accents` (WHILE), `fn_cfg` |
| Stored procedures, incl. parameterised (IN) | 05, 06, 08 | `sp_refresh_marts()`, `sp_seller_scorecard(IN p_seller_id)`, `sp_load_core()` |
| Dynamic SQL (PREPARE / EXECUTE / DEALLOCATE) | 08 | idempotent index helpers |
| User variables / session variables | all analysis files, 08, 10 | `SET @ws = CAST(fn_cfg('window_start') AS DATE)` |
| Views (CREATE OR REPLACE VIEW) | 09 | `v_fact_order_items`, `v_dim_customer` … |
| "Materialized views" via marts + refresh procedure | 05, 10 | `mart_*` + `sp_refresh_marts()` + `mart_refresh_log` |
| Indexes, composite index, EXPLAIN, EXPLAIN ANALYZE, SARGability | 08 (+ docs/performance.md) | `idx_orders_status_purchase`; `YEAR(ts)=2018` vs range |
| Recursive CTE | 09, a02, a03, a14, 05 | date spine (09, a03), month spine (a02, 05), month offsets (05) |
| Chained CTEs (one per logical step) | every analysis file | a12 `valid_orders → first_orders → next_day → customer_level` |
| CTE with column list | 02, 07, a07, a15, a16, a17 | `WITH expected (table_name, expected_rows) AS (…)` |
| INNER JOIN | most files | a04 four-table join |
| LEFT JOIN | a02, a03, a14, a15, a16, 09 | zero-fill from a spine; lead funnel LEFT JOIN chain (a16) |
| RIGHT JOIN | a08 | second half of the FULL OUTER JOIN emulation |
| FULL OUTER JOIN (emulated) | a08 | `LEFT JOIN … UNION ALL … RIGHT JOIN … WHERE left IS NULL` |
| SELF JOIN | a19 | `order_categories a JOIN order_categories b ON a.order_id = b.order_id AND a.category_en < b.category_en` |
| CROSS JOIN | a03, a17, a19, 09 | day × region grid (a03), tiers × sellers (a17) |
| Anti-join (NOT EXISTS, LEFT JOIN … IS NULL) | a09, a10, 07, a14 | delivered orders without review (two ways) |
| Semi-join (EXISTS, IN subquery) | a09, a03, a12 | customers with a 5-star review (two ways) |
| Correlated subquery | a06, a09, a12 | seller late % vs **its own** category average (a06) |
| Scalar subquery | a07, a09, a20, 07, 10 | overall freight ratio (a20), last date in data (a09) |
| IN subquery | a09, 09 | `customer_id IN (SELECT …)` |
| UNION, UNION ALL (count difference shown) | a10, 02, 07, a06, a13, a15 | `union_vs_union_all` (a10) |
| INTERSECT, EXCEPT (native, 8.0.31+) + join equivalents | a10 | lapsed 2017 customers, sellers active in both H1s |
| GROUP BY / HAVING | most files | lanes HAVING ≥ cfg min (a04), seller HAVING ≥ 30 (a06), pairs HAVING ≥ 20 (a19) |
| GROUP BY … WITH ROLLUP + GROUPING() | a20 | region × weight-band subtotals |
| ROW_NUMBER | 06, 09, a04, a12, a14, a17, a18 | dedup (06), order sequence (a12), islands (a14) |
| RANK | 05 | rank in category (`sp_seller_scorecard`) |
| DENSE_RANK | a04, a06 | lanes by late orders; worst sellers per category |
| NTILE | a13, 09 | R and M quintiles |
| PERCENT_RANK | a17, 05 | Pareto seller rank |
| CUME_DIST | a12 | p25 / p75 days to second order |
| LAG / LEAD | a02, a15, a16, a12, a14, 05 | MoM / YoY (LAG 1/12), next purchase day (LEAD), gap after island (LEAD) |
| FIRST_VALUE / LAST_VALUE (+ why LAST_VALUE needs the full frame) | a13, a15, a16 | first vs latest category per customer |
| Window frames (ROWS BETWEEN …) | a02, a03, a13, a17, 05 | 3-month and 7-day moving averages, running totals, full frame |
| Running totals | a02, a17, 05 | `SUM(gmv) OVER (ORDER BY … ROWS UNBOUNDED PRECEDING)` |
| Moving averages | a02 (3-month), a03 (7-day) | `AVG(...) OVER (… ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)` |
| Named WINDOW clause | a02, a13, 05 | `WINDOW w AS (ORDER BY month_start)` |
| CASE (classification, pivots, buckets) | a04, a05, a11, a08, a20 … | score 1-5 pivot (a05), M0-M6 pivot (a11), region matrix (a04) |
| Conditional aggregation (FILTER substitute) | a01, a04, a05, a14, a15, 07 | `SUM(CASE WHEN … THEN 1 ELSE 0 END)` |
| COALESCE / NULLIF | 06, a01, a02, a03, a18 … | NULLIF for safe division and empty strings; COALESCE zero-fill |
| Date functions: DATE_FORMAT, DATEDIFF, TIMESTAMPDIFF, PERIOD_DIFF, STR_TO_DATE, DATE_ADD / DATE_SUB, INTERVAL | 06, 09, a02, a11, a12, a14, a15, a16 | TIMESTAMPDIFF stage hours (a15), STR_TO_DATE (06), DATE_ADD 90-day window (a16) |
| String functions: LOWER, UPPER, TRIM, SUBSTRING, CONCAT, REPLACE, LEFT/RIGHT, LPAD, LOCATE, CHAR_LENGTH, GROUP_CONCAT | 04, 06, a18, a16, a11 | display labels (a18), `fn_strip_accents` (04) |
| Collations (accent-insensitive vs binary) | 00, 06, a18 | `COLLATE utf8mb4_bin` distinct counts (a18) |
| REGEXP | 07 | control characters `REGEXP '[[:cntrl:]]'` |
| Spatial: ST_Distance_Sphere, POINT | 09, a20 | seller ↔ customer distance bands |
| De-duplication | 06 (R08), a04 (DISTINCT order-lane), a19 (DISTINCT order-category) | latest review per order |
| Cohort analysis | a11, 05 (mart_cohort_retention) | M0-M6 retention matrix |
| Funnel analysis | a15 (order lifecycle), a16 (seller acquisition) | step + cumulative conversion |
| Gaps-and-islands | a14 | `month_idx − ROW_NUMBER()` |
| Pareto / concentration | a17, 05 | top 1/5/10/20/50% share; sellers for 80% |
| Median / percentiles | a04, a12, a15, a16, 05 | ROW_NUMBER + COUNT median; CUME_DIST percentiles |
| MoM / YoY | a02, 05 | LAG(1), LAG(12) on a zero-filled spine |
| Fan-out trap | a07 | naive vs pre-aggregated join |
| Reconciliation | a08, 07 | items vs payments, R$0.01 tolerance |
| Basket analysis (support, confidence, lift) | a19 | category pairs |
| Data-quality audit pattern | 07 | single UNION ALL report with PASS/WARN/FAIL |

Not covered by this dataset: sessionisation of clickstream (same LAG + running-SUM pattern as a14).
