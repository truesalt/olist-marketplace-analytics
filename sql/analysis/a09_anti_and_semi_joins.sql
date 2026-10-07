/* ============================================================================
   File        : a09_anti_and_semi_joins.sql
   Purpose     : "Find rows that DO / DO NOT have a match" - the anti-join and semi-join
                 patterns, each written two ways to prove they return the same answer.
   Business Q  : Which orders never got reviewed; which sellers went silent; which customers
                 left a 5-star review?
   SQL concepts: anti-join (NOT EXISTS vs LEFT JOIN ... IS NULL), semi-join (EXISTS vs
                 IN subquery), correlated scalar subquery (each seller's last sale date),
                 uncorrelated scalar subquery (last date in the data), UNION ALL comparison
   Output      : delivered_without_review, silent_sellers_90d, customers_with_5star
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/analysis/a09_anti_and_semi_joins.sql
   ========================================================================== */

SET @ws      = CAST(fn_cfg('window_start') AS DATE);
SET @we      = CAST(fn_cfg('window_end') AS DATE);
SET @we_excl = @we + INTERVAL 1 DAY;

-- @query: delivered_without_review
SELECT 'NOT EXISTS (anti-join)' AS method,
       COUNT(*)                 AS delivered_orders_without_review,
       ROUND(100 * COUNT(*) / (SELECT COUNT(*) FROM orders
                               WHERE is_valid_delivery = 1
                                 AND purchase_ts >= @ws AND purchase_ts < @we_excl), 2)
                                   AS pct_of_valid_deliveries
FROM orders AS o
WHERE o.is_valid_delivery = 1
  AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
  AND NOT EXISTS (SELECT 1 FROM order_reviews AS r WHERE r.order_id = o.order_id)
UNION ALL
SELECT 'LEFT JOIN ... IS NULL (anti-join)',
       COUNT(*),
       ROUND(100 * COUNT(*) / (SELECT COUNT(*) FROM orders
                               WHERE is_valid_delivery = 1
                                 AND purchase_ts >= @ws AND purchase_ts < @we_excl), 2)
FROM orders AS o
LEFT JOIN order_reviews AS r ON r.order_id = o.order_id
WHERE o.is_valid_delivery = 1
  AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
  AND r.order_id IS NULL;
-- Reading the result: both anti-join forms agree: 636 valid deliveries (0.67%) never received a review.

-- @query: silent_sellers_90d
WITH seller_sales AS (             -- every seller with >= 1 valid sale in the window
  SELECT oi.seller_id,
         COUNT(DISTINCT o.order_id)        AS orders,
         SUM(oi.price + oi.freight_value)  AS gmv
  FROM order_items AS oi
  INNER JOIN orders AS o ON o.order_id = oi.order_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
  GROUP BY oi.seller_id
),
with_last_sale AS (
  SELECT ss.seller_id, ss.orders, ss.gmv,
         -- correlated scalar subquery: this seller's most recent valid sale
         (SELECT MAX(o2.purchase_ts)
          FROM order_items AS oi2
          INNER JOIN orders AS o2 ON o2.order_id = oi2.order_id
          WHERE oi2.seller_id = ss.seller_id
            AND o2.order_status NOT IN ('canceled', 'unavailable')
            AND o2.purchase_ts >= @ws AND o2.purchase_ts < @we_excl) AS last_sale_ts,
         -- uncorrelated scalar subquery: the last purchase in the whole window
         (SELECT MAX(purchase_ts) FROM orders
          WHERE purchase_ts >= @ws AND purchase_ts < @we_excl)           AS data_end_ts
  FROM seller_sales AS ss
)
SELECT seller_id,
       orders,
       ROUND(gmv, 2)                          AS gmv_brl,
       DATE(last_sale_ts)                     AS last_sale_date,
       DATEDIFF(data_end_ts, last_sale_ts)    AS days_silent
FROM with_last_sale
WHERE DATEDIFF(data_end_ts, last_sale_ts) > 90       -- no sale in the final 90 days
ORDER BY gmv DESC, seller_id;
-- Reading the result: 1,232 sellers that sold in the window made no sale in its final 90 days (median 269
--   days silent). Together they had sold R$2,353,158; the largest sold R$74,137.92 before going quiet. This
--   is a win-back list for seller success.

-- @query: customers_with_5star
SELECT 'EXISTS (semi-join)'      AS method,
       COUNT(DISTINCT c.customer_unique_id) AS customers_with_5star,
       ROUND(100 * COUNT(DISTINCT c.customer_unique_id)
             / (SELECT COUNT(DISTINCT customer_unique_id) FROM customers), 2) AS pct_of_all_customers
FROM customers AS c
WHERE EXISTS (SELECT 1
              FROM orders AS o
              INNER JOIN order_reviews AS r ON r.order_id = o.order_id
              WHERE o.customer_id = c.customer_id
                AND r.review_score = 5)
UNION ALL
SELECT 'IN subquery (semi-join)',
       COUNT(DISTINCT c.customer_unique_id),
       ROUND(100 * COUNT(DISTINCT c.customer_unique_id)
             / (SELECT COUNT(DISTINCT customer_unique_id) FROM customers), 2)
FROM customers AS c
WHERE c.customer_id IN (SELECT o.customer_id
                        FROM orders AS o
                        INNER JOIN order_reviews AS r ON r.order_id = o.order_id
                        WHERE r.review_score = 5);
-- Reading the result: EXISTS and IN agree: 55,363 people (57.61% of all customers) left at least one 5-star
--   review.
