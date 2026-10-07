/* ============================================================================
   File        : a02_monthly_trends.sql
   Purpose     : Monthly GMV trend with month-over-month and year-over-year growth,
                 a 3-month moving average and a running total.
   Business Q  : Q1 - How is GMV growing MoM and YoY?
   SQL concepts: WITH RECURSIVE month spine (generate_series substitute), LEFT JOIN zero-fill,
                 DATE_FORMAT month truncation, LAG(1) / LAG(12), moving average with
                 ROWS BETWEEN 2 PRECEDING AND CURRENT ROW, running total SUM() OVER (ORDER BY),
                 named WINDOW clause, NULLIF
   Output      : monthly_trend
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/analysis/a02_monthly_trends.sql
   ========================================================================== */

SET SESSION cte_max_recursion_depth = 5000;
SET @ws      = CAST(fn_cfg('window_start') AS DATE);
SET @we      = CAST(fn_cfg('window_end') AS DATE);
SET @we_excl = @we + INTERVAL 1 DAY;

-- @query: monthly_trend
WITH RECURSIVE month_spine (month_start) AS (   -- one row per month, even months with no sales
  SELECT CAST(DATE_FORMAT(@ws, '%Y-%m-01') AS DATE)
  UNION ALL
  SELECT month_start + INTERVAL 1 MONTH
  FROM month_spine
  WHERE month_start + INTERVAL 1 MONTH <= @we
),
monthly_sales AS (                               -- GMV and orders per purchase month
  SELECT CAST(DATE_FORMAT(o.purchase_ts, '%Y-%m-01') AS DATE) AS month_start,  -- DATE_TRUNC('month')
         COUNT(DISTINCT o.order_id)                           AS orders,
         SUM(oi.price + oi.freight_value)                     AS gmv
  FROM orders AS o
  INNER JOIN order_items AS oi ON oi.order_id = o.order_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws
    AND o.purchase_ts <  @we_excl
  GROUP BY CAST(DATE_FORMAT(o.purchase_ts, '%Y-%m-01') AS DATE)
),
filled AS (                                      -- zero-fill: LEFT JOIN from the spine
  SELECT ms.month_start,
         COALESCE(s.orders, 0) AS orders,
         COALESCE(s.gmv, 0)    AS gmv
  FROM month_spine AS ms
  LEFT JOIN monthly_sales AS s ON s.month_start = ms.month_start
)
SELECT
  DATE_FORMAT(month_start, '%Y-%m')                                    AS `year_month`,
  orders,
  ROUND(gmv, 2)                                                        AS gmv_brl,
  ROUND(gmv / NULLIF(orders, 0), 2)                                    AS aov_brl,
  ROUND(LAG(gmv, 1) OVER w, 2)                                         AS gmv_prev_month,
  ROUND(100 * (gmv - LAG(gmv, 1) OVER w) / NULLIF(LAG(gmv, 1) OVER w, 0), 2)   AS gmv_mom_pct,
  ROUND(LAG(gmv, 12) OVER w, 2)                                        AS gmv_same_month_last_year,
  ROUND(100 * (gmv - LAG(gmv, 12) OVER w) / NULLIF(LAG(gmv, 12) OVER w, 0), 2) AS gmv_yoy_pct,
  ROUND(AVG(gmv) OVER (w ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2) AS gmv_3m_moving_avg,
  ROUND(SUM(gmv) OVER (w ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 2) AS gmv_running_total
FROM filled
WINDOW w AS (ORDER BY month_start)   -- spine guarantees consecutive months, so LAG(12) = same month last year
ORDER BY month_start;
-- Reading the result: GMV grew from R$136,943 (Jan-2017) to a R$1,172,192 peak in Nov-2017 (Black Friday,
--   +53.28% MoM), then plateaued around R$1.0-1.16M a month in 2018. YoY growth decays from +704.65%
--   (Jan-2018, tiny 2017 base) to +50.62% (Aug-2018), and the 3-month average slips from R$1,151,531
--   (May-2018) to R$1,019,046 (Aug-2018): hyper-growth is over. The running total ends at R$15,683,706.74,
--   identical to a01.
