/* ============================================================================
   File        : a01_executive_kpis.sql
   Purpose     : One-row health check of the marketplace for the analysis window.
   Business Q  : Q1 - How big and healthy is the marketplace?
   SQL concepts: chained CTEs, aggregates, COUNT(DISTINCT), NULLIF (safe division), ROUND,
                 CROSS JOIN of one-row CTEs, conditional aggregation
   Output      : kpi_summary (gmv_brl, orders, customers, sellers, aov_brl, items_per_order,
                 freight_share_pct, on_time_pct, avg_delivery_days, low_review_pct, repeat_180d_pct)
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/analysis/a01_executive_kpis.sql
   ========================================================================== */

SET @ws      = CAST(fn_cfg('window_start') AS DATE);
SET @we_excl = CAST(fn_cfg('window_end') AS DATE) + INTERVAL 1 DAY;   -- exclusive upper bound
SET @low_max = CAST(fn_cfg('low_review_max') AS UNSIGNED);

-- @query: kpi_summary
WITH valid_orders AS (            -- valid order = not canceled/unavailable, purchased in window
  SELECT o.order_id, c.customer_unique_id, o.is_valid_delivery, o.is_late, o.delivery_days
  FROM orders AS o
  INNER JOIN customers AS c ON c.customer_id = o.customer_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws
    AND o.purchase_ts <  @we_excl
),
item_totals AS (                  -- money lives on items: GMV = price + freight (per order)
  SELECT vo.order_id,
         COUNT(*)              AS n_items,
         SUM(oi.price)         AS merchandise,
         SUM(oi.freight_value) AS freight
  FROM valid_orders AS vo
  INNER JOIN order_items AS oi ON oi.order_id = vo.order_id   -- INNER: orders need >= 1 item
  GROUP BY vo.order_id
),
order_kpis AS (                   -- order-level totals (one row)
  SELECT COUNT(*)                                     AS orders,
         COUNT(DISTINCT vo.customer_unique_id)        AS customers,
         SUM(it.merchandise + it.freight)             AS gmv,
         SUM(it.freight)                              AS freight,
         SUM(it.n_items)                              AS items,
         SUM(vo.is_valid_delivery)                    AS valid_deliveries,
         SUM(CASE WHEN vo.is_late = 1 THEN 1 ELSE 0 END) AS late_orders,
         AVG(CASE WHEN vo.is_valid_delivery = 1 THEN vo.delivery_days END) AS avg_delivery_days
  FROM valid_orders AS vo
  INNER JOIN item_totals AS it ON it.order_id = vo.order_id
),
seller_kpis AS (                  -- sellers with >= 1 item in a valid order
  SELECT COUNT(DISTINCT oi.seller_id) AS sellers
  FROM valid_orders AS vo
  INNER JOIN order_items AS oi ON oi.order_id = vo.order_id
),
review_kpis AS (                  -- low-review share among valid orders that have a review
  SELECT COUNT(*)                                            AS reviewed_orders,
         SUM(CASE WHEN r.review_score <= @low_max THEN 1 ELSE 0 END) AS low_review_orders
  FROM valid_orders AS vo
  INNER JOIN item_totals   AS it ON it.order_id = vo.order_id
  INNER JOIN order_reviews AS r  ON r.order_id = vo.order_id
),
repeat_kpis AS (                  -- 180-day repeat rate among repeat-eligible customers
  SELECT SUM(repeat_180d)    AS repeaters,
         SUM(eligible_repeat) AS eligible
  FROM v_dim_customer
  WHERE eligible_repeat = 1
)
SELECT
  ROUND(ok.gmv, 2)                                               AS gmv_brl,
  ok.orders,
  ok.customers,
  sk.sellers,
  ROUND(ok.gmv / NULLIF(ok.orders, 0), 2)                        AS aov_brl,
  ROUND(ok.items / NULLIF(ok.orders, 0), 3)                      AS items_per_order,
  ROUND(100 * ok.freight / NULLIF(ok.gmv, 0), 2)                 AS freight_share_pct,
  ROUND(100 * (1 - ok.late_orders / NULLIF(ok.valid_deliveries, 0)), 2) AS on_time_pct,
  ROUND(ok.avg_delivery_days, 2)                                 AS avg_delivery_days,
  ROUND(100 * rk.low_review_orders / NULLIF(rk.reviewed_orders, 0), 2)  AS low_review_pct,
  ROUND(100 * pk.repeaters / NULLIF(pk.eligible, 0), 2)          AS repeat_180d_pct
FROM order_kpis AS ok
CROSS JOIN seller_kpis AS sk
CROSS JOIN review_kpis AS rk
CROSS JOIN repeat_kpis AS pk;
-- Reading the result: R$15,683,706.74 GMV from 97,905 valid orders (Jan-2017..Aug-2018), 94,703 customers and
--   3,029 selling sellers; AOV R$160.19, 1.141 items per order, freight = 14.25% of GMV. Operations look fine
--   on average (93.14% on time, 12.54 days to deliver, 13.84% low reviews), but only 1.99% of repeat-eligible
--   customers order again within 180 days: growth is almost entirely new-customer acquisition.
