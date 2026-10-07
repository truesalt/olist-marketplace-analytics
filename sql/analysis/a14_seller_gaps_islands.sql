/* ============================================================================
   File        : a14_seller_gaps_islands.sql
   Purpose     : Measure how continuously sellers sell: consecutive active-month streaks
                 ("islands"), the inactive gaps between them, and monthly seller churn.
   Business Q  : Q5 - How stable is seller supply?
   SQL concepts: month index (PERIOD_DIFF), GAPS-AND-ISLANDS (month_idx - ROW_NUMBER() is
                 constant inside a run of consecutive months), island length, LEAD to measure
                 the gap after each island, recursive month spine, NOT EXISTS look-ahead,
                 churn rate
   Output      : seller_streaks_summary, seller_churn_monthly
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/analysis/a14_seller_gaps_islands.sql
   Definitions : churn episode = >= 2 consecutive inactive months after being active
                 (an internal gap the seller came back from, or a trailing gap at window end).
   ========================================================================== */

SET SESSION cte_max_recursion_depth = 5000;
SET @ws       = CAST(fn_cfg('window_start') AS DATE);
SET @we       = CAST(fn_cfg('window_end') AS DATE);
SET @we_excl  = @we + INTERVAL 1 DAY;
SET @last_idx = PERIOD_DIFF(DATE_FORMAT(@we, '%Y%m'), DATE_FORMAT(@ws, '%Y%m'));  -- 19 = Aug-2018

-- @query: seller_streaks_summary
WITH seller_months AS (          -- distinct active months per seller as 0-based month index
  SELECT DISTINCT oi.seller_id,
         PERIOD_DIFF(DATE_FORMAT(o.purchase_ts, '%Y%m'), DATE_FORMAT(@ws, '%Y%m')) AS month_idx
  FROM order_items AS oi
  INNER JOIN orders AS o ON o.order_id = oi.order_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
),
islands AS (                     -- consecutive months share the same (month_idx - row_number)
  SELECT seller_id, month_idx,
         -- ROW_NUMBER() is BIGINT UNSIGNED in MySQL: cast to SIGNED or 0 - 1 raises an out-of-range error
         month_idx - CAST(ROW_NUMBER() OVER (PARTITION BY seller_id ORDER BY month_idx) AS SIGNED)
           AS island_key
  FROM seller_months
),
island_bounds AS (               -- one row per streak
  SELECT seller_id, island_key,
         MIN(month_idx) AS start_idx, MAX(month_idx) AS end_idx, COUNT(*) AS island_len
  FROM islands
  GROUP BY seller_id, island_key
),
island_gaps AS (                 -- inactive months after each streak (until next streak or window end)
  SELECT ib.*,
         LEAD(start_idx) OVER (PARTITION BY seller_id ORDER BY start_idx) AS next_start_idx,
         COALESCE(LEAD(start_idx) OVER (PARTITION BY seller_id ORDER BY start_idx), @last_idx + 1)
           - end_idx - 1                                                   AS gap_after
  FROM island_bounds AS ib
),
per_seller AS (
  SELECT seller_id,
         COUNT(*)                                                                    AS n_islands,
         SUM(island_len)                                                             AS active_months,
         MAX(island_len)                                                             AS longest_streak,
         SUM(CASE WHEN gap_after >= 2 AND next_start_idx IS NOT NULL THEN 1 ELSE 0 END)
           AS internal_churn_gaps,
         MAX(CASE WHEN gap_after >= 2 AND next_start_idx IS NULL     THEN 1 ELSE 0 END) AS trailing_churn
  FROM island_gaps
  GROUP BY seller_id
)
SELECT COUNT(*)                                                         AS sellers,
       ROUND(AVG(n_islands), 2)                                         AS avg_streaks_per_seller,
       ROUND(SUM(active_months) / SUM(n_islands), 2)                    AS avg_streak_length_months,
       ROUND(AVG(longest_streak), 2)                                    AS avg_longest_streak_months,
       SUM(CASE WHEN n_islands = 1 THEN 1 ELSE 0 END)                   AS sellers_one_unbroken_streak,
       SUM(CASE WHEN internal_churn_gaps > 0 THEN 1 ELSE 0 END)         AS sellers_returned_after_2m_gap,
       SUM(trailing_churn)                                              AS sellers_inactive_last_2m_plus,
       SUM(internal_churn_gaps) + SUM(trailing_churn)                   AS churn_episodes,
       ROUND(100 * SUM(CASE WHEN internal_churn_gaps > 0 OR trailing_churn = 1 THEN 1 ELSE 0 END)
             / COUNT(*), 1)                                             AS pct_sellers_with_churn_episode,
       ROUND(100 * SUM(trailing_churn) / COUNT(*), 1)                   AS pct_sellers_inactive_at_end
FROM per_seller;
-- Reading the result: 3,029 sellers average 1.71 activity streaks of 3.12 months each; 1,766 sold in a single
--   unbroken streak. 58.5% had at least one churn episode (2+ silent months), and 46.9% (1,421) were silent
--   in the window's last two months.

-- @query: seller_churn_monthly
WITH RECURSIVE month_idx_spine (month_idx) AS (
  SELECT 0
  UNION ALL
  SELECT month_idx + 1 FROM month_idx_spine WHERE month_idx < @last_idx
),
seller_months AS (
  SELECT DISTINCT oi.seller_id,
         PERIOD_DIFF(DATE_FORMAT(o.purchase_ts, '%Y%m'), DATE_FORMAT(@ws, '%Y%m')) AS month_idx
  FROM order_items AS oi
  INNER JOIN orders AS o ON o.order_id = oi.order_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
),
first_month AS (
  SELECT seller_id, MIN(month_idx) AS first_idx
  FROM seller_months
  GROUP BY seller_id
),
active AS (
  SELECT month_idx, COUNT(*) AS active_sellers
  FROM seller_months
  GROUP BY month_idx
),
new_sellers AS (
  SELECT first_idx AS month_idx, COUNT(*) AS new_sellers
  FROM first_month
  GROUP BY first_idx
),
churned AS (                     -- active in m-1, then silent in m AND m+1 (start of a 2+ month gap)
  SELECT prev.month_idx + 1 AS month_idx, COUNT(*) AS churned_sellers
  FROM seller_months AS prev
  WHERE prev.month_idx + 2 <= @last_idx          -- both following months must be observable
    AND NOT EXISTS (SELECT 1 FROM seller_months AS cur
                    WHERE cur.seller_id = prev.seller_id AND cur.month_idx = prev.month_idx + 1)
    AND NOT EXISTS (SELECT 1 FROM seller_months AS nxt
                    WHERE nxt.seller_id = prev.seller_id AND nxt.month_idx = prev.month_idx + 2)
  GROUP BY prev.month_idx + 1
)
SELECT DATE_FORMAT(@ws + INTERVAL s.month_idx MONTH, '%Y-%m')                 AS `year_month`,
       COALESCE(a.active_sellers, 0)                                           AS active_sellers,
       COALESCE(n.new_sellers, 0)                                              AS new_sellers,
       CASE WHEN s.month_idx BETWEEN 1 AND @last_idx - 1
            THEN COALESCE(ch.churned_sellers, 0) END                           AS churned_sellers,
       CASE WHEN s.month_idx BETWEEN 1 AND @last_idx - 1
            THEN ROUND(100 * COALESCE(ch.churned_sellers, 0) / NULLIF(prev_a.active_sellers, 0), 2)
       END                                                                     AS churn_rate_pct
FROM month_idx_spine AS s
LEFT JOIN active      AS a      ON a.month_idx      = s.month_idx
LEFT JOIN active      AS prev_a ON prev_a.month_idx = s.month_idx - 1
LEFT JOIN new_sellers AS n      ON n.month_idx      = s.month_idx
LEFT JOIN churned     AS ch     ON ch.month_idx     = s.month_idx
ORDER BY s.month_idx;
-- Reading the result: active sellers grew from 226 (Jan-2017) to 1,266 (Aug-2018), but every month 13%-23% of
--   the previous month's active sellers start a 2+ month gap (Jul-2018: 191 sellers, 16.35%). Supply growth
--   depends on onboarding 111-199 new sellers a month in 2018.
