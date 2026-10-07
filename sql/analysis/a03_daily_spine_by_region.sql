/* ============================================================================
   File        : a03_daily_spine_by_region.sql
   Purpose     : True average daily orders per customer region, counting days with ZERO
                 orders - a plain GROUP BY silently skips those days and overstates the average.
   Business Q  : What is the true average daily order count per region, counting zero days?
   SQL concepts: WITH RECURSIVE date spine, CROSS JOIN (every day x every region), LEFT JOIN,
                 COALESCE zero-fill, 7-day moving average (ROWS BETWEEN 6 PRECEDING AND CURRENT
                 ROW) partitioned by region, naive-vs-correct comparison
   Output      : daily_orders_region, avg_daily_orders_region
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/analysis/a03_daily_spine_by_region.sql
   ========================================================================== */

SET SESSION cte_max_recursion_depth = 5000;
SET @ws      = CAST(fn_cfg('window_start') AS DATE);
SET @we      = CAST(fn_cfg('window_end') AS DATE);
SET @we_excl = @we + INTERVAL 1 DAY;

-- @query: daily_orders_region
WITH RECURSIVE day_spine (day) AS (              -- every calendar day of the window
  SELECT @ws
  UNION ALL
  SELECT day + INTERVAL 1 DAY FROM day_spine WHERE day < @we
),
regions AS (
  SELECT DISTINCT region FROM customers
),
daily_orders AS (                                -- only days that HAVE orders appear here
  SELECT DATE(o.purchase_ts) AS day, c.region, COUNT(*) AS orders
  FROM orders AS o
  INNER JOIN customers AS c ON c.customer_id = o.customer_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws
    AND o.purchase_ts <  @we_excl
    AND EXISTS (SELECT 1 FROM order_items AS oi WHERE oi.order_id = o.order_id)
  GROUP BY DATE(o.purchase_ts), c.region
)
SELECT ds.day,
       r.region                                     AS customer_region,
       COALESCE(d.orders, 0)                        AS orders,          -- zero-filled
       ROUND(AVG(COALESCE(d.orders, 0)) OVER (PARTITION BY r.region ORDER BY ds.day
                                              ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 2)
                                                    AS orders_7d_moving_avg
FROM day_spine AS ds
CROSS JOIN regions AS r                             -- day x region grid
LEFT JOIN daily_orders AS d
       ON d.day = ds.day
      AND d.region = r.region
ORDER BY r.region, ds.day;
-- Reading the result: 3,040 rows = 608 days x 5 regions, zero-filled. The busiest day is 2017-11-24 (Black
--   Friday) with 808 Southeast orders.

-- @query: avg_daily_orders_region
WITH RECURSIVE day_spine (day) AS (
  SELECT @ws
  UNION ALL
  SELECT day + INTERVAL 1 DAY FROM day_spine WHERE day < @we
),
regions AS (
  SELECT DISTINCT region FROM customers
),
daily_orders AS (
  SELECT DATE(o.purchase_ts) AS day, c.region, COUNT(*) AS orders
  FROM orders AS o
  INNER JOIN customers AS c ON c.customer_id = o.customer_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws
    AND o.purchase_ts <  @we_excl
    AND EXISTS (SELECT 1 FROM order_items AS oi WHERE oi.order_id = o.order_id)
  GROUP BY DATE(o.purchase_ts), c.region
),
grid AS (
  SELECT r.region, ds.day, COALESCE(d.orders, 0) AS orders
  FROM day_spine AS ds
  CROSS JOIN regions AS r
  LEFT JOIN daily_orders AS d ON d.day = ds.day AND d.region = r.region
)
SELECT region                                                   AS customer_region,
       COUNT(*)                                                 AS days_in_window,
       SUM(CASE WHEN orders > 0 THEN 1 ELSE 0 END)              AS days_with_orders,
       SUM(CASE WHEN orders = 0 THEN 1 ELSE 0 END)              AS zero_order_days,
       SUM(orders)                                              AS total_orders,
       ROUND(AVG(orders), 2)                                    AS avg_daily_orders_true,
       ROUND(AVG(CASE WHEN orders > 0 THEN orders END), 2)      AS avg_daily_orders_naive,  -- skips zero days
       ROUND(100 * (AVG(CASE WHEN orders > 0 THEN orders END) - AVG(orders))
             / NULLIF(AVG(orders), 0), 2)                       AS naive_overstatement_pct
FROM grid
GROUP BY region
ORDER BY avg_daily_orders_true DESC;
-- Reading the result: the North has 70 zero-order days out of 608; a plain GROUP BY average skips them and
--   overstates North's daily orders by 13.01% (3.40 vs a true 3.01 per day). Southeast: 110.44 orders per
--   day, only 6 zero days, 1.00% overstatement. Sparse segments need a spine.
