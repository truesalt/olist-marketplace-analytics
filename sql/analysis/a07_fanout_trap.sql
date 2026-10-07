/* ============================================================================
   File        : a07_fanout_trap.sql
   Purpose     : Show how joining two "many" tables (items and payments) on order_id
                 multiplies rows and overstates revenue, and the correct pattern:
                 aggregate each side to one row per order BEFORE joining.
   Business Q  : Why do naive joins overstate revenue?
   SQL concepts: fan-out (many-to-many through a shared key), pre-aggregation in CTEs,
                 UNION ALL comparison table, scalar subquery as the reference value
   Output      : gmv_naive_vs_correct
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/analysis/a07_fanout_trap.sql
   ========================================================================== */

SET @ws      = CAST(fn_cfg('window_start') AS DATE);
SET @we_excl = CAST(fn_cfg('window_end') AS DATE) + INTERVAL 1 DAY;

-- @query: gmv_naive_vs_correct
WITH valid_orders AS (
  SELECT o.order_id
  FROM orders AS o
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws
    AND o.purchase_ts <  @we_excl
),
-- WRONG: an order with 2 items and 3 payments produces 2 x 3 = 6 joined rows, so every
-- item price is counted 3 times and every payment 2 times.
naive_join AS (
  SELECT COUNT(*)                         AS joined_rows,
         SUM(oi.price + oi.freight_value) AS gmv,
         SUM(op.payment_value)            AS paid
  FROM valid_orders AS vo
  INNER JOIN order_items    AS oi ON oi.order_id = vo.order_id
  INNER JOIN order_payments AS op ON op.order_id = vo.order_id
),
-- RIGHT: collapse each side to ONE row per order first, then join 1:1.
items_per_order AS (
  SELECT oi.order_id, SUM(oi.price + oi.freight_value) AS order_gmv, COUNT(*) AS n_items
  FROM valid_orders AS vo
  INNER JOIN order_items AS oi ON oi.order_id = vo.order_id
  GROUP BY oi.order_id
),
payments_per_order AS (
  SELECT op.order_id, SUM(op.payment_value) AS order_paid, COUNT(*) AS n_payments
  FROM valid_orders AS vo
  INNER JOIN order_payments AS op ON op.order_id = vo.order_id
  GROUP BY op.order_id
),
correct_join AS (
  SELECT COUNT(*)            AS joined_rows,
         SUM(i.order_gmv)    AS gmv,
         SUM(p.order_paid)   AS paid
  FROM items_per_order AS i
  INNER JOIN payments_per_order AS p ON p.order_id = i.order_id
),
results (method, joined_rows, gmv_brl, paid_brl) AS (
  SELECT '1. naive: items JOIN payments', joined_rows, gmv, paid FROM naive_join
  UNION ALL
  SELECT '2. correct: pre-aggregate both sides per order', joined_rows, gmv, paid FROM correct_join
)
SELECT method,
       joined_rows,
       ROUND(gmv_brl, 2)                                                       AS gmv_brl,
       ROUND(100 * (gmv_brl - (SELECT gmv FROM correct_join)) / (SELECT gmv FROM correct_join), 2)
                                                                               AS gmv_overstatement_pct,
       ROUND(paid_brl, 2)                                                      AS paid_brl,
       ROUND(100 * (paid_brl - (SELECT paid FROM correct_join)) / (SELECT paid FROM correct_join), 2)
                                                                               AS paid_overstatement_pct,
       (SELECT COUNT(*) FROM items_per_order i INNER JOIN payments_per_order p ON p.order_id = i.order_id
        WHERE i.n_items > 1 AND p.n_payments > 1)                      AS orders_with_multi_items_and_payments
FROM results
ORDER BY method;
-- Reading the result: joining items to payments directly turns 97,905 orders into 116,664 rows and overstates
--   GMV by 4.56% (R$16,398,421 vs R$15,683,707) and payments by 28.06% (R$20,088,048 vs R$15,686,469).
--   Pre-aggregating each side to one row per order gives the correct R$15,683,706.74.
