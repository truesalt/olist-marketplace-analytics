/* ============================================================================
   File        : a12_repeat_and_time_to_second.sql
   Purpose     : Who comes back within 180 days, how fast, and does the first-order
                 experience (late delivery, voucher) relate to coming back?
                 Also exports the customer-level table used by the Python tests (T3-T5).
   Business Q  : Q3/Q4 - Does a late first order reduce repeat purchase? Do voucher-paid
                 first orders bring customers back? How fast do repeaters return?
   SQL concepts: ROW_NUMBER (order sequence), LEAD (next purchase day), DATEDIFF,
                 MEDIAN via ROW_NUMBER + COUNT OVER, percentiles via CUME_DIST (first row with
                 cume_dist >= p), correlated subqueries (first category / first value), EXISTS,
                 eligibility rule against right-censoring
   Output      : time_to_second_order_dist, repeat_by_first_order_late,
                 repeat_by_first_order_voucher, customer_level_for_stats
   Run with  : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/analysis/a12_repeat_and_time_to_second.sql
   Definitions : repeat_180d = a valid order on a LATER calendar day within 180 days of the first
                 order (same-day extra checkouts happen before delivery, so they are not a "return").
                 eligible = first order on/before window_end - 180 days, so every eligible customer
                 had the full 180 days to come back (no right-censoring).
   ========================================================================== */

SET @ws       = CAST(fn_cfg('window_start') AS DATE);
SET @we       = CAST(fn_cfg('window_end') AS DATE);
SET @we_excl  = @we + INTERVAL 1 DAY;
SET @horizon  = CAST(fn_cfg('repeat_horizon_days') AS UNSIGNED);
SET @eligible_cutoff = DATE_SUB(@we, INTERVAL @horizon DAY);       -- 2018-03-04 with defaults

-- @query: time_to_second_order_dist
WITH valid_orders AS (
  SELECT o.order_id, c.customer_unique_id, DATE(o.purchase_ts) AS purchase_date, o.purchase_ts
  FROM orders AS o
  INNER JOIN customers AS c ON c.customer_id = o.customer_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
    AND EXISTS (SELECT 1 FROM order_items AS oi WHERE oi.order_id = o.order_id)
),
purchase_days AS (               -- LEAD over DISTINCT purchase days = next LATER day
  SELECT customer_unique_id, purchase_date,
         LEAD(purchase_date) OVER (PARTITION BY customer_unique_id
                                   ORDER BY purchase_date) AS next_purchase_date,
         ROW_NUMBER()        OVER (PARTITION BY customer_unique_id ORDER BY purchase_date) AS day_seq
  FROM (SELECT DISTINCT customer_unique_id, purchase_date FROM valid_orders) AS d
),
returners AS (                   -- eligible customers who came back (any time in the window)
  SELECT customer_unique_id, DATEDIFF(next_purchase_date, purchase_date) AS days_to_second
  FROM purchase_days
  WHERE day_seq = 1
    AND next_purchase_date IS NOT NULL
    AND purchase_date <= @eligible_cutoff
),
dist AS (
  SELECT days_to_second,
         ROW_NUMBER() OVER (ORDER BY days_to_second) AS rn,
         COUNT(*)     OVER ()                        AS n,
         CUME_DIST()  OVER (ORDER BY days_to_second) AS cume
  FROM returners
)
SELECT MAX(n)                                                              AS eligible_returners,
       MIN(CASE WHEN cume >= 0.25 THEN days_to_second END)                 AS p25_days,
       ROUND(AVG(CASE WHEN rn IN (FLOOR((n + 1) / 2), CEIL((n + 1) / 2)) THEN days_to_second END), 1)
         AS median_days,
       MIN(CASE WHEN cume >= 0.75 THEN days_to_second END)                 AS p75_days,
       ROUND(AVG(days_to_second), 1)                                       AS mean_days,
       ROUND(100 * AVG(CASE WHEN days_to_second <= 30  THEN 1 ELSE 0 END), 1) AS pct_within_30d,
       ROUND(100 * AVG(CASE WHEN days_to_second <= 90  THEN 1 ELSE 0 END), 1) AS pct_within_90d,
       ROUND(100 * AVG(CASE WHEN days_to_second <= 180 THEN 1 ELSE 0 END), 1) AS pct_within_180d
FROM dist;
-- Reading the result: 1,629 repeat-eligible customers came back on a later day. Median 105 days to the second
--   purchase (p25 34, p75 202, mean 133.7); only 23.0% return within 30 days and 70.0% within 180 days. A
--   second-order nudge has to work over months, not days.

-- @query: repeat_by_first_order_late
WITH valid_orders AS (
  SELECT o.order_id, c.customer_unique_id, o.purchase_ts, DATE(o.purchase_ts) AS purchase_date, o.is_late
  FROM orders AS o
  INNER JOIN customers AS c ON c.customer_id = o.customer_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
    AND EXISTS (SELECT 1 FROM order_items AS oi WHERE oi.order_id = o.order_id)
),
first_orders AS (                -- ROW_NUMBER = 1 -> each person's first valid order
  SELECT *
  FROM (SELECT vo.*, ROW_NUMBER() OVER (PARTITION BY customer_unique_id
                                        ORDER BY purchase_ts, order_id) AS order_seq
        FROM valid_orders AS vo) AS seq
  WHERE order_seq = 1
),
next_day AS (
  SELECT customer_unique_id,
         LEAD(purchase_date) OVER (PARTITION BY customer_unique_id
                                   ORDER BY purchase_date) AS next_purchase_date,
         ROW_NUMBER()        OVER (PARTITION BY customer_unique_id ORDER BY purchase_date) AS day_seq
  FROM (SELECT DISTINCT customer_unique_id, purchase_date FROM valid_orders) AS d
),
customer_level AS (
  SELECT f.customer_unique_id, f.is_late AS first_late,
         CASE WHEN DATEDIFF(nd.next_purchase_date, f.purchase_date) <= @horizon THEN 1 ELSE 0 END
           AS repeat_180d
  FROM first_orders AS f
  INNER JOIN next_day AS nd ON nd.customer_unique_id = f.customer_unique_id AND nd.day_seq = 1
  WHERE f.purchase_date <= @eligible_cutoff              -- repeat-eligible only
    AND f.is_late IS NOT NULL                            -- first order was a valid delivery
)
SELECT CASE first_late WHEN 1 THEN 'late first order' ELSE 'on-time first order' END AS first_order_delivery,
       COUNT(*)                                   AS eligible_customers,
       SUM(repeat_180d)                           AS repeat_customers,
       ROUND(100 * AVG(repeat_180d), 2)           AS repeat_180d_pct
FROM customer_level
GROUP BY first_late
ORDER BY first_late;
-- Reading the result: among repeat-eligible customers whose first order was validly delivered, 1.58% of those
--   with a LATE first order came back within 180 days (62 of 3,918) vs 2.02% after an on-time first order
--   (1,054 of 52,108). Significance and confounders: T3 and T5 in results/stats/.

-- @query: repeat_by_first_order_voucher
WITH valid_orders AS (
  SELECT o.order_id, c.customer_unique_id, o.purchase_ts, DATE(o.purchase_ts) AS purchase_date
  FROM orders AS o
  INNER JOIN customers AS c ON c.customer_id = o.customer_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
    AND EXISTS (SELECT 1 FROM order_items AS oi WHERE oi.order_id = o.order_id)
),
first_orders AS (
  SELECT *
  FROM (SELECT vo.*, ROW_NUMBER() OVER (PARTITION BY customer_unique_id
                                        ORDER BY purchase_ts, order_id) AS order_seq
        FROM valid_orders AS vo) AS seq
  WHERE order_seq = 1
),
next_day AS (
  SELECT customer_unique_id,
         LEAD(purchase_date) OVER (PARTITION BY customer_unique_id
                                   ORDER BY purchase_date) AS next_purchase_date,
         ROW_NUMBER()        OVER (PARTITION BY customer_unique_id ORDER BY purchase_date) AS day_seq
  FROM (SELECT DISTINCT customer_unique_id, purchase_date FROM valid_orders) AS d
),
customer_level AS (
  SELECT f.customer_unique_id,
         CASE WHEN EXISTS (SELECT 1 FROM order_payments AS op
                           WHERE op.order_id = f.order_id AND op.payment_type = 'voucher')
              THEN 1 ELSE 0 END                                                     AS first_voucher,
         CASE WHEN DATEDIFF(nd.next_purchase_date, f.purchase_date) <= @horizon THEN 1 ELSE 0 END
           AS repeat_180d
  FROM first_orders AS f
  INNER JOIN next_day AS nd ON nd.customer_unique_id = f.customer_unique_id AND nd.day_seq = 1
  WHERE f.purchase_date <= @eligible_cutoff
)
SELECT CASE first_voucher WHEN 1 THEN 'voucher used on first order' ELSE 'no voucher' END
  AS first_order_payment,
       COUNT(*)                                   AS eligible_customers,
       SUM(repeat_180d)                           AS repeat_customers,
       ROUND(100 * AVG(repeat_180d), 2)           AS repeat_180d_pct
FROM customer_level
GROUP BY first_voucher
ORDER BY first_voucher;
-- Reading the result: 2.50% of customers who used a voucher on their first order repeated (58 of 2,316) vs
--   1.97% without one (1,082 of 54,967). Voucher users self-select, so this is not a causal effect (T4).

-- @query: customer_level_for_stats
WITH valid_orders AS (
  SELECT o.order_id, c.customer_unique_id, c.region, o.purchase_ts, DATE(o.purchase_ts)
    AS purchase_date, o.is_late
  FROM orders AS o
  INNER JOIN customers AS c ON c.customer_id = o.customer_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
    AND EXISTS (SELECT 1 FROM order_items AS oi WHERE oi.order_id = o.order_id)
),
first_orders AS (
  SELECT *
  FROM (SELECT vo.*, ROW_NUMBER() OVER (PARTITION BY customer_unique_id
                                        ORDER BY purchase_ts, order_id) AS order_seq
        FROM valid_orders AS vo) AS seq
  WHERE order_seq = 1
),
next_day AS (
  SELECT customer_unique_id,
         LEAD(purchase_date) OVER (PARTITION BY customer_unique_id
                                   ORDER BY purchase_date) AS next_purchase_date,
         ROW_NUMBER()        OVER (PARTITION BY customer_unique_id ORDER BY purchase_date) AS day_seq
  FROM (SELECT DISTINCT customer_unique_id, purchase_date FROM valid_orders) AS d
)
SELECT f.customer_unique_id,
       DATE_FORMAT(f.purchase_date, '%Y-%m')                                        AS first_order_month,
       CASE WHEN f.purchase_date <= @eligible_cutoff THEN 1 ELSE 0 END             AS eligible_repeat,
       f.is_late                                                  AS first_late,   -- NULL = no valid delivery
       CASE WHEN EXISTS (SELECT 1 FROM order_payments AS op
                         WHERE op.order_id = f.order_id AND op.payment_type = 'voucher')
            THEN 1 ELSE 0 END                                                       AS first_voucher,
       (SELECT SUM(oi.price + oi.freight_value) FROM order_items AS oi
        WHERE oi.order_id = f.order_id)        AS `first_value`,  -- backticks: FIRST_VALUE is a reserved word
       f.region,
       (SELECT p.category_en                    -- category of the most expensive item
        FROM order_items AS oi
        INNER JOIN products AS p ON p.product_id = oi.product_id
        WHERE oi.order_id = f.order_id
        ORDER BY oi.price DESC, oi.order_item_id
        LIMIT 1)                                                                    AS first_category,
       DATEDIFF(nd.next_purchase_date, f.purchase_date)                            AS days_to_second,
       CASE WHEN DATEDIFF(nd.next_purchase_date, f.purchase_date) <= @horizon
            THEN 1 ELSE 0 END                                                       AS repeat_180d
FROM first_orders AS f
INNER JOIN next_day AS nd ON nd.customer_unique_id = f.customer_unique_id AND nd.day_seq = 1
ORDER BY f.customer_unique_id;
-- Reading the result: one row per customer (94,703); 57,283 are repeat-eligible (2,316 + 54,967 above).
--   notebooks/01_statistical_tests.ipynb reads this table for T3-T5.
