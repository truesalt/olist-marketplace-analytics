/* ============================================================================
   File        : a04_delivery_sla_by_lane.sql
   Purpose     : Delivery-promise performance per seller-state -> customer-state lane:
                 late %, average and median delivery days, ranked by late orders.
   Business Q  : Q2 - Which seller->customer lanes break the delivery promise most?
   SQL concepts: multi-table INNER JOIN, SELECT DISTINCT de-dup, GROUP BY + HAVING
                 (threshold from cfg), conditional aggregation, window-based MEDIAN
                 (ROW_NUMBER + COUNT OVER), DENSE_RANK, CASE pivot (region matrix)
   Output      : lane_sla_state, lane_sla_region_matrix
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/analysis/a04_delivery_sla_by_lane.sql
   ========================================================================== */

SET @ws       = CAST(fn_cfg('window_start') AS DATE);
SET @we_excl  = CAST(fn_cfg('window_end') AS DATE) + INTERVAL 1 DAY;
SET @min_lane = CAST(fn_cfg('min_orders_lane') AS UNSIGNED);

-- @query: lane_sla_state
WITH order_lanes AS (          -- one row per (order, seller state); o/c/oi/s = orders/customers/items/sellers
  SELECT DISTINCT                -- several items from the same seller state count once
         o.order_id,
         s.region AS seller_region,   s.state AS seller_state,
         c.region AS customer_region, c.state AS customer_state,
         o.is_late, o.delivery_days, o.delay_days
  FROM orders AS o
  INNER JOIN customers   AS c  ON c.customer_id = o.customer_id
  INNER JOIN order_items AS oi ON oi.order_id   = o.order_id
  INNER JOIN sellers     AS s  ON s.seller_id   = oi.seller_id
  WHERE o.is_valid_delivery = 1                  -- delivered, dated, no timestamp anomaly
    AND o.purchase_ts >= @ws
    AND o.purchase_ts <  @we_excl
),
ranked AS (                      -- position of each order within its lane, for the median
  SELECT ol.*,
         ROW_NUMBER() OVER (PARTITION BY seller_state, customer_state ORDER BY delivery_days) AS rn,
         COUNT(*)     OVER (PARTITION BY seller_state, customer_state)                        AS n
  FROM order_lanes AS ol
),
lane_stats AS (
  SELECT seller_region, seller_state, customer_region, customer_state,
         COUNT(*)                                        AS delivered_orders,
         SUM(is_late)                                    AS late_orders,
         ROUND(100 * SUM(is_late) / COUNT(*), 2)         AS late_pct,
         ROUND(AVG(delivery_days), 1)                    AS avg_delivery_days,
         -- MEDIAN: average of the middle row (odd n) or the two middle rows (even n)
         ROUND(AVG(CASE WHEN rn IN (FLOOR((n + 1) / 2), CEIL((n + 1) / 2)) THEN delivery_days END), 1)
                                                         AS median_delivery_days,
         ROUND(AVG(CASE WHEN is_late = 1 THEN delay_days END), 1) AS avg_days_late_when_late
  FROM ranked
  GROUP BY seller_region, seller_state, customer_region, customer_state
  HAVING COUNT(*) >= @min_lane               -- ignore thin lanes (noise)
)
SELECT DENSE_RANK() OVER (ORDER BY late_orders DESC) AS late_orders_rank,
       DENSE_RANK() OVER (ORDER BY late_pct DESC)    AS late_pct_rank,
       ls.*
FROM lane_stats AS ls
ORDER BY late_orders_rank, late_pct DESC;
-- Reading the result: 70 lanes have >= 100 delivered orders. Volume drives the late COUNT: SP->SP is #1 with
--   1,424 late orders at only 4.70% late, SP->RJ is #2 with 1,149 late at 14.22%. The worst RATES are long
--   hauls into the Northeast: SP->AL 23.62%, MA->SP 21.19%, SP->MA 19.62%. The 10 lanes with the most late
--   orders account for 4,286 of the 6,107 late orders on qualifying lanes (sum of rows 1-10).

-- @query: lane_sla_region_matrix
WITH order_lanes AS (
  SELECT DISTINCT o.order_id, s.region AS seller_region, c.region AS customer_region, o.is_late
  FROM orders AS o
  INNER JOIN customers   AS c  ON c.customer_id = o.customer_id
  INNER JOIN order_items AS oi ON oi.order_id   = o.order_id
  INNER JOIN sellers     AS s  ON s.seller_id   = oi.seller_id
  WHERE o.is_valid_delivery = 1
    AND o.purchase_ts >= @ws
    AND o.purchase_ts <  @we_excl
)
SELECT seller_region,                -- rows = seller region, columns = customer region (late %)
  ROUND(100 * SUM(CASE WHEN customer_region = 'North'       THEN is_late END)
            / NULLIF(SUM(CASE WHEN customer_region = 'North'       THEN 1 END), 0), 1) AS to_north_late_pct,
  ROUND(100 * SUM(CASE WHEN customer_region = 'Northeast'   THEN is_late END)
            / NULLIF(SUM(CASE WHEN customer_region = 'Northeast' THEN 1 END), 0), 1) AS to_northeast_late_pct,
  ROUND(100 * SUM(CASE WHEN customer_region = 'Center-West' THEN is_late END)
            / NULLIF(SUM(CASE WHEN customer_region = 'Center-West' THEN 1 END), 0), 1)
              AS to_center_west_late_pct,
  ROUND(100 * SUM(CASE WHEN customer_region = 'Southeast'   THEN is_late END)
            / NULLIF(SUM(CASE WHEN customer_region = 'Southeast' THEN 1 END), 0), 1) AS to_southeast_late_pct,
  ROUND(100 * SUM(CASE WHEN customer_region = 'South'       THEN is_late END)
            / NULLIF(SUM(CASE WHEN customer_region = 'South'       THEN 1 END), 0), 1) AS to_south_late_pct,
  ROUND(100 * SUM(is_late) / COUNT(*), 1)                                           AS all_customers_late_pct,
  COUNT(*)                                                                             AS delivered_orders
FROM order_lanes
GROUP BY seller_region
ORDER BY delivered_orders DESC;
-- Reading the result: Southeast sellers ship 79,352 of the deliveries; they are late 6.4% of the time inside
--   the Southeast but 13.0% into the Northeast and 9.1% into the North. Northeast-bound deliveries are the
--   weak spot from every major seller region (South -> Northeast 13.0%, Center-West -> 12.2%).
