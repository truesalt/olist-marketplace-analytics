/* ============================================================================
   File        : a11_cohort_retention.sql
   Purpose     : Monthly acquisition cohorts: of the customers whose first order was in
                 month X, what share ordered again 1, 2, ... 6 months later?
   Business Q  : Q3 - Do customers come back month after month?
   SQL concepts: first-order month per customer_unique_id (MIN in a CTE), PERIOD_DIFF for
                 month offsets (DATE_TRUNC/AGE substitute), cohort size, CASE pivot M0-M6,
                 retention %, NULL vs 0 for months not yet observable (right-censoring)
   Output      : cohort_matrix, cohort_long
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/analysis/a11_cohort_retention.sql
   ========================================================================== */

SET @ws      = CAST(fn_cfg('window_start') AS DATE);
SET @we      = CAST(fn_cfg('window_end') AS DATE);
SET @we_excl = @we + INTERVAL 1 DAY;
SET @we_ym   = DATE_FORMAT(@we, '%Y%m');                -- last observable month, e.g. 201808

-- @query: cohort_matrix
WITH customer_months AS (        -- distinct (person, active month) pairs from valid orders
  SELECT DISTINCT c.customer_unique_id, DATE_FORMAT(o.purchase_ts, '%Y%m') AS ym
  FROM orders AS o
  INNER JOIN customers AS c ON c.customer_id = o.customer_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
    AND EXISTS (SELECT 1 FROM order_items AS oi WHERE oi.order_id = o.order_id)
),
cohorts AS (                     -- cohort = month of the person's FIRST valid order
  SELECT customer_unique_id, MIN(ym) AS cohort_ym
  FROM customer_months
  GROUP BY customer_unique_id
),
activity AS (                    -- months_since = 0 for the cohort month, 1 for the next, ...
  SELECT co.cohort_ym, cm.customer_unique_id, PERIOD_DIFF(cm.ym, co.cohort_ym) AS months_since
  FROM customer_months AS cm
  INNER JOIN cohorts AS co ON co.customer_unique_id = cm.customer_unique_id
)
SELECT CONCAT(LEFT(cohort_ym, 4), '-', RIGHT(cohort_ym, 2))                     AS cohort_month,
       COUNT(DISTINCT customer_unique_id)                                       AS cohort_size,
       -- CASE pivot: % of the cohort active N months later; NULL = month not observed yet
       ROUND(100 * COUNT(DISTINCT CASE WHEN months_since = 0 THEN customer_unique_id END)
             / COUNT(DISTINCT customer_unique_id), 2)                           AS m0_pct,
       CASE WHEN PERIOD_DIFF(@we_ym, cohort_ym) >= 1 THEN
         ROUND(100 * COUNT(DISTINCT CASE WHEN months_since = 1 THEN customer_unique_id END)
               / COUNT(DISTINCT customer_unique_id), 2) END                     AS m1_pct,
       CASE WHEN PERIOD_DIFF(@we_ym, cohort_ym) >= 2 THEN
         ROUND(100 * COUNT(DISTINCT CASE WHEN months_since = 2 THEN customer_unique_id END)
               / COUNT(DISTINCT customer_unique_id), 2) END                     AS m2_pct,
       CASE WHEN PERIOD_DIFF(@we_ym, cohort_ym) >= 3 THEN
         ROUND(100 * COUNT(DISTINCT CASE WHEN months_since = 3 THEN customer_unique_id END)
               / COUNT(DISTINCT customer_unique_id), 2) END                     AS m3_pct,
       CASE WHEN PERIOD_DIFF(@we_ym, cohort_ym) >= 4 THEN
         ROUND(100 * COUNT(DISTINCT CASE WHEN months_since = 4 THEN customer_unique_id END)
               / COUNT(DISTINCT customer_unique_id), 2) END                     AS m4_pct,
       CASE WHEN PERIOD_DIFF(@we_ym, cohort_ym) >= 5 THEN
         ROUND(100 * COUNT(DISTINCT CASE WHEN months_since = 5 THEN customer_unique_id END)
               / COUNT(DISTINCT customer_unique_id), 2) END                     AS m5_pct,
       CASE WHEN PERIOD_DIFF(@we_ym, cohort_ym) >= 6 THEN
         ROUND(100 * COUNT(DISTINCT CASE WHEN months_since = 6 THEN customer_unique_id END)
               / COUNT(DISTINCT customer_unique_id), 2) END                     AS m6_pct
FROM activity
GROUP BY cohort_ym
ORDER BY cohort_ym;
-- Reading the result: retention is tiny. Only 0.22%-0.71% of a cohort orders again in month 1 (best: Oct-2017
--   at 0.71%), and no later month exceeds 0.60%. Cells after the window end are NULL (not observed), not 0:
--   that is the right-censoring guard.

-- @query: cohort_long
WITH customer_months AS (
  SELECT DISTINCT c.customer_unique_id, DATE_FORMAT(o.purchase_ts, '%Y%m') AS ym
  FROM orders AS o
  INNER JOIN customers AS c ON c.customer_id = o.customer_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
    AND EXISTS (SELECT 1 FROM order_items AS oi WHERE oi.order_id = o.order_id)
),
cohorts AS (
  SELECT customer_unique_id, MIN(ym) AS cohort_ym
  FROM customer_months
  GROUP BY customer_unique_id
),
cohort_sizes AS (
  SELECT cohort_ym, COUNT(*) AS cohort_size
  FROM cohorts
  GROUP BY cohort_ym
),
activity AS (
  SELECT co.cohort_ym, PERIOD_DIFF(cm.ym, co.cohort_ym) AS months_since, COUNT(*) AS active_customers
  FROM customer_months AS cm
  INNER JOIN cohorts AS co ON co.customer_unique_id = cm.customer_unique_id
  GROUP BY co.cohort_ym, PERIOD_DIFF(cm.ym, co.cohort_ym)
)
SELECT CONCAT(LEFT(a.cohort_ym, 4), '-', RIGHT(a.cohort_ym, 2))   AS cohort_month,
       a.months_since,
       a.active_customers,
       cs.cohort_size,
       ROUND(100 * a.active_customers / cs.cohort_size, 2)         AS retention_pct
FROM activity AS a
INNER JOIN cohort_sizes AS cs ON cs.cohort_ym = a.cohort_ym
ORDER BY a.cohort_ym, a.months_since;
-- Reading the result: 207 cohort x month cells; average month-1 retention across cohorts is 0.48%. This long
--   format feeds the Power BI matrix and the cohort heatmap chart.
