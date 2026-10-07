/* ============================================================================
   File        : a19_basket_self_join.sql
   Purpose     : Market-basket analysis at category level: which categories appear in the
                 same order more often than chance would predict?
   Business Q  : Which categories are bought together?
   SQL concepts: SELF-JOIN of order categories on order_id with a.category_en < b.category_en
                 (each unordered pair once, no self-pairs), support, confidence, lift,
                 GROUP BY + HAVING minimum pair count
   Output      : category_pairs
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/analysis/a19_basket_self_join.sql
   Metrics     : support(A,B)   = orders with A and B / all orders
                 confidence(A->B) = orders with A and B / orders with A
                 lift(A,B)      = support(A,B) / (support(A) * support(B)); > 1 = bought together
                                  more often than if they were independent
   ========================================================================== */

SET @ws        = CAST(fn_cfg('window_start') AS DATE);
SET @we_excl   = CAST(fn_cfg('window_end') AS DATE) + INTERVAL 1 DAY;
SET @min_pairs = 20;                          -- PROJECT_SPEC: minimum co-occurring orders per pair

-- @query: category_pairs
WITH order_categories AS (       -- distinct categories in each valid order
  SELECT DISTINCT oi.order_id, p.category_en
  FROM order_items AS oi
  INNER JOIN orders   AS o ON o.order_id   = oi.order_id
  INNER JOIN products AS p ON p.product_id = oi.product_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
),
total AS (                       -- all valid orders, and how many span 2+ categories
  SELECT COUNT(*)                                       AS n_orders,
         SUM(CASE WHEN n_categories >= 2 THEN 1 ELSE 0 END) AS multi_category_orders
  FROM (SELECT order_id, COUNT(*) AS n_categories FROM order_categories GROUP BY order_id) AS per_order
),
category_orders AS (
  SELECT category_en, COUNT(*) AS orders_with_category
  FROM order_categories
  GROUP BY category_en
),
pairs AS (                       -- the self-join: same order, two different categories
  SELECT a.category_en AS category_a,
         b.category_en AS category_b,
         COUNT(*)      AS pair_orders
  FROM order_categories AS a
  INNER JOIN order_categories AS b
          ON b.order_id = a.order_id
         AND a.category_en < b.category_en    -- A<B: (x,y) kept once, (y,x) and (x,x) dropped
  GROUP BY a.category_en, b.category_en
  HAVING COUNT(*) >= @min_pairs
)
SELECT p.category_a,
       p.category_b,
       p.pair_orders,
       ROUND(100 * p.pair_orders / t.n_orders, 3)                           AS support_pct,
       ROUND(100 * p.pair_orders / ca.orders_with_category, 2)             AS confidence_a_to_b_pct,
       ROUND(100 * p.pair_orders / cb.orders_with_category, 2)             AS confidence_b_to_a_pct,
       ROUND((p.pair_orders / t.n_orders)
             / ((ca.orders_with_category / t.n_orders) * (cb.orders_with_category / t.n_orders)), 2) AS lift,
       t.n_orders                                                          AS all_orders,
       t.multi_category_orders,
       ROUND(100 * t.multi_category_orders / t.n_orders, 2)                AS pct_orders_multi_category
FROM pairs AS p
INNER JOIN category_orders AS ca ON ca.category_en = p.category_a
INNER JOIN category_orders AS cb ON cb.category_en = p.category_b
CROSS JOIN total AS t
ORDER BY lift DESC, pair_orders DESC;
-- Reading the result: only 783 of 97,905 orders (0.80%) contain 2+ categories, so just 5 pairs reach 20
--   co-orders. Lift is below 1 for 4 of them because single-category baskets dominate. bed_bath_table +
--   home_confort (43 orders, lift 1.13; 10.83% of home_confort orders also contain bed_bath_table) is the one
--   genuine affinity. Cross-sell is not a material lever in this data.
