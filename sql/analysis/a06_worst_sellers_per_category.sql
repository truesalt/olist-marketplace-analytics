/* ============================================================================
   File        : a06_worst_sellers_per_category.sql
   Purpose     : Within each product category, find the sellers whose late-delivery rate is
                 above that category's average, and the 3 worst per category.
   Business Q  : Q2 - Which sellers are dragging each category down?
   SQL concepts: correlated scalar subquery (seller vs its own category average), GROUP BY +
                 HAVING (min orders from cfg), DENSE_RANK() OVER (PARTITION BY category),
                 top-N per group by filtering a window result in an outer CTE (MySQL has no
                 QUALIFY), UNION ALL for a grand-total row
   Output      : worst_sellers_top3, sellers_above_category_avg_count
   Run with : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/analysis/a06_worst_sellers_per_category.sql
   ========================================================================== */

SET @ws         = CAST(fn_cfg('window_start') AS DATE);
SET @we_excl    = CAST(fn_cfg('window_end') AS DATE) + INTERVAL 1 DAY;
SET @min_seller = CAST(fn_cfg('min_orders_seller') AS UNSIGNED);
SET @low_max    = CAST(fn_cfg('low_review_max') AS UNSIGNED);

-- @query: worst_sellers_top3
WITH seller_category_orders AS (   -- one row per (order, seller, category) among valid deliveries
  SELECT DISTINCT o.order_id, oi.seller_id, p.category_en, o.is_late, r.review_score
  FROM orders AS o
  INNER JOIN order_items AS oi ON oi.order_id   = o.order_id
  INNER JOIN products    AS p  ON p.product_id  = oi.product_id
  LEFT JOIN  order_reviews AS r ON r.order_id   = o.order_id
  WHERE o.is_valid_delivery = 1
    AND o.purchase_ts >= @ws
    AND o.purchase_ts <  @we_excl
),
category_stats AS (                -- the benchmark: late % of the whole category
  SELECT category_en,
         COUNT(*)                         AS category_orders,
         SUM(is_late)                     AS category_late_orders,
         100 * SUM(is_late) / COUNT(*)    AS category_late_pct
  FROM seller_category_orders
  GROUP BY category_en
),
seller_stats AS (                  -- each seller inside each category (enough volume only)
  SELECT seller_id, category_en,
         COUNT(*)                         AS delivered_orders,
         SUM(is_late)                     AS late_orders,
         100 * SUM(is_late) / COUNT(*)    AS seller_late_pct,
         100 * SUM(CASE WHEN review_score <= @low_max THEN 1 ELSE 0 END)
             / NULLIF(SUM(CASE WHEN review_score IS NOT NULL THEN 1 ELSE 0 END), 0) AS low_review_pct
  FROM seller_category_orders
  GROUP BY seller_id, category_en
  HAVING COUNT(*) >= @min_seller
),
above_average AS (                 -- correlated subquery: compare with THIS seller's category
  SELECT ss.*,
         (SELECT cs.category_late_pct FROM category_stats AS cs
          WHERE cs.category_en = ss.category_en)                 AS category_late_pct
  FROM seller_stats AS ss
  WHERE ss.seller_late_pct > (SELECT cs.category_late_pct
                              FROM category_stats AS cs
                              WHERE cs.category_en = ss.category_en)
),
ranked AS (                        -- rank inside each category; QUALIFY-style filter comes next
  SELECT aa.*,
         DENSE_RANK() OVER (PARTITION BY category_en ORDER BY seller_late_pct DESC) AS rank_in_category
  FROM above_average AS aa
)
SELECT category_en,
       rank_in_category,
       seller_id,
       delivered_orders,
       late_orders,
       ROUND(seller_late_pct, 1)                       AS seller_late_pct,
       ROUND(category_late_pct, 1)                     AS category_late_pct,
       ROUND(seller_late_pct - category_late_pct, 1)   AS gap_pp,
       ROUND(low_review_pct, 1)                        AS seller_low_review_pct
FROM ranked
WHERE rank_in_category <= 3
ORDER BY category_en, rank_in_category, seller_id;
-- Reading the result: 97 seller rows (top-3 per category across 44 categories) are above their category's
--   late rate with >= 30 deliveries in it; the largest gap is +23.6 pp. Example: health_beauty seller
--   06a2c3af... is 20.0% late vs a 7.6% category average and has 16.9% low reviews.

-- @query: sellers_above_category_avg_count
WITH seller_category_orders AS (
  SELECT DISTINCT o.order_id, oi.seller_id, p.category_en, o.is_late
  FROM orders AS o
  INNER JOIN order_items AS oi ON oi.order_id  = o.order_id
  INNER JOIN products    AS p  ON p.product_id = oi.product_id
  WHERE o.is_valid_delivery = 1
    AND o.purchase_ts >= @ws
    AND o.purchase_ts <  @we_excl
),
category_stats AS (
  SELECT category_en, SUM(is_late) AS category_late_orders, 100 * SUM(is_late) / COUNT(*) AS category_late_pct
  FROM seller_category_orders
  GROUP BY category_en
),
seller_stats AS (
  SELECT seller_id, category_en, COUNT(*) AS delivered_orders, SUM(is_late) AS late_orders,
         100 * SUM(is_late) / COUNT(*) AS seller_late_pct
  FROM seller_category_orders
  GROUP BY seller_id, category_en
  HAVING COUNT(*) >= @min_seller
),
flagged AS (
  SELECT ss.*, CASE WHEN ss.seller_late_pct > cs.category_late_pct THEN 1 ELSE 0 END AS is_above_avg
  FROM seller_stats AS ss
  INNER JOIN category_stats AS cs ON cs.category_en = ss.category_en
),
per_category AS (
  SELECT f.category_en,
         COUNT(*)                                             AS qualifying_sellers,
         SUM(f.is_above_avg)                                  AS sellers_above_avg,
         SUM(CASE WHEN f.is_above_avg = 1 THEN f.late_orders ELSE 0 END) AS late_orders_from_above_avg,
         MAX(cs.category_late_orders)                         AS category_late_orders
  FROM flagged AS f
  INNER JOIN category_stats AS cs ON cs.category_en = f.category_en
  GROUP BY f.category_en
)
SELECT category_en, qualifying_sellers, sellers_above_avg, late_orders_from_above_avg, category_late_orders,
       ROUND(100 * late_orders_from_above_avg / NULLIF(category_late_orders, 0), 1)
         AS share_of_category_late_pct
FROM per_category
UNION ALL                          -- grand total across categories
SELECT 'ALL CATEGORIES', SUM(qualifying_sellers), SUM(sellers_above_avg), SUM(late_orders_from_above_avg),
       (SELECT SUM(category_late_orders) FROM category_stats),
       ROUND(100 * SUM(late_orders_from_above_avg)
             / (SELECT SUM(category_late_orders) FROM category_stats), 1)
FROM per_category
ORDER BY late_orders_from_above_avg DESC;
-- Reading the result: of 624 qualifying seller-category pairs, 257 are above their category average and they
--   produce 3,120 of all 6,533 late seller-category deliveries (47.8%). A seller-quality programme aimed at
--   ~41% of qualifying sellers addresses about half of late deliveries.
