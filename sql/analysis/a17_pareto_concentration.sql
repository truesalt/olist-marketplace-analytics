/* ============================================================================
   File        : a17_pareto_concentration.sql
   Purpose     : How concentrated is GMV? Share of GMV from the top 1/5/10/20/50% of sellers,
                 how many sellers make 80% of GMV, and the same curve for categories.
   Business Q  : Q6 - How dependent is GMV on a few sellers and categories (Pareto risk)?
   SQL concepts: running SUM() OVER (ORDER BY gmv DESC ROWS UNBOUNDED PRECEDING) / SUM() OVER ()
                 = cumulative share, PERCENT_RANK, ROW_NUMBER, CROSS JOIN with a tiers table,
                 conditional aggregation, UNION ALL
   Output      : pareto_sellers_summary, pareto_categories
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/analysis/a17_pareto_concentration.sql
   ========================================================================== */

SET @ws      = CAST(fn_cfg('window_start') AS DATE);
SET @we_excl = CAST(fn_cfg('window_end') AS DATE) + INTERVAL 1 DAY;

-- @query: pareto_sellers_summary
WITH seller_gmv AS (
  SELECT oi.seller_id, SUM(oi.price + oi.freight_value) AS gmv
  FROM order_items AS oi
  INNER JOIN orders AS o ON o.order_id = oi.order_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
  GROUP BY oi.seller_id
),
ranked AS (
  SELECT seller_id, gmv,
         ROW_NUMBER()   OVER (ORDER BY gmv DESC, seller_id)                       AS gmv_rank,
         COUNT(*)       OVER ()                                                   AS n_sellers,
         PERCENT_RANK() OVER (ORDER BY gmv DESC, seller_id)                       AS pct_rank,  -- 0 = top
         SUM(gmv) OVER (ORDER BY gmv DESC, seller_id
                        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
           / SUM(gmv) OVER ()                                                     AS cum_gmv_share
  FROM seller_gmv
),
tiers (tier_order, tier, top_fraction) AS (
  SELECT 1, 'top 1% of sellers',  0.01 UNION ALL
  SELECT 2, 'top 5% of sellers',  0.05 UNION ALL
  SELECT 3, 'top 10% of sellers', 0.10 UNION ALL
  SELECT 4, 'top 20% of sellers', 0.20 UNION ALL
  SELECT 5, 'top 50% of sellers', 0.50
)
SELECT t.tier_order,
       t.tier,
       SUM(CASE WHEN r.pct_rank <= t.top_fraction THEN 1 ELSE 0 END)                AS sellers_in_tier,
       ROUND(100 * SUM(CASE WHEN r.pct_rank <= t.top_fraction THEN 1 ELSE 0 END) / MAX(r.n_sellers), 2)
                                                                                   AS pct_of_sellers,
       ROUND(100 * SUM(CASE WHEN r.pct_rank <= t.top_fraction THEN r.gmv ELSE 0 END) / SUM(r.gmv), 2)
                                                                                   AS gmv_share_pct
FROM tiers AS t
CROSS JOIN ranked AS r                   -- every seller evaluated against every tier
GROUP BY t.tier_order, t.tier
UNION ALL
SELECT 6, 'sellers needed for 80% of GMV',
       MIN(gmv_rank),
       ROUND(100 * MIN(gmv_rank) / MAX(n_sellers), 2),
       ROUND(100 * MIN(cum_gmv_share), 2)
FROM ranked
WHERE cum_gmv_share >= 0.80
ORDER BY tier_order;
-- Reading the result: the top 1% of sellers (31) generate 25.73% of GMV and the top 20% (606) 81.86%; 556
--   sellers (18.36%) cover 80%. This is a classic 80/20 marketplace: losing a few dozen sellers is material.

-- @query: pareto_categories
WITH category_gmv AS (
  SELECT p.category_en,
         COUNT(DISTINCT o.order_id)        AS orders,
         SUM(oi.price + oi.freight_value)  AS gmv
  FROM order_items AS oi
  INNER JOIN orders   AS o ON o.order_id   = oi.order_id
  INNER JOIN products AS p ON p.product_id = oi.product_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
  GROUP BY p.category_en
)
SELECT ROW_NUMBER() OVER (ORDER BY gmv DESC, category_en)                          AS category_rank,
       category_en,
       orders,
       ROUND(gmv, 2)                                                               AS gmv_brl,
       ROUND(100 * gmv / SUM(gmv) OVER (), 2)                                      AS gmv_share_pct,
       ROUND(100 * SUM(gmv) OVER (ORDER BY gmv DESC, category_en
                                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
             / SUM(gmv) OVER (), 2)                                                AS cum_gmv_share_pct,
       ROUND(PERCENT_RANK() OVER (ORDER BY gmv DESC, category_en), 4)              AS pct_rank
FROM category_gmv
ORDER BY category_rank;
-- Reading the result: 74 categories; the top 7 (health_beauty 9.13%, watches_gifts 8.26%, bed_bath_table
--   7.90%, sports_leisure, computers_accessories, furniture_decor, housewares) make 49.88% of GMV.
