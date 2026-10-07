/* ============================================================================
   File        : a16_seller_acquisition_funnel.sql
   Purpose     : Seller-acquisition funnel by marketing channel: MQL -> won (signed) ->
                 first sale -> active in >= 3 of its first 6 months, plus early GMV per win.
   Business Q  : Q5 - Which seller-acquisition channels produce sellers that actually sell?
   SQL concepts: LEFT JOIN chain (each stage may be missing), GROUP BY origin, conversion %,
                 window MEDIAN of days-to-close per origin, GROUP_CONCAT (STRING_AGG substitute)
                 with ORDER BY + SEPARATOR, unpivot via UNION ALL, LAG step conversion
   Output      : lead_funnel_by_origin, lead_funnel_overall, won_seller_value_by_origin
   Run with  : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/analysis/a16_seller_acquisition_funnel.sql
   Caveat      : leads signed late (2018) had less time to make a first sale before the data ends.
   ========================================================================== */

SET SESSION group_concat_max_len = 100000;      -- default 1024 chars would truncate the lists
SET @ws      = CAST(fn_cfg('window_start') AS DATE);
SET @we_excl = CAST(fn_cfg('window_end') AS DATE) + INTERVAL 1 DAY;

-- @query: lead_funnel_by_origin
WITH seller_sales AS (           -- valid sales of every seller (item grain)
  SELECT oi.seller_id, DATE(o.purchase_ts) AS sale_date, oi.price + oi.freight_value AS item_gmv
  FROM order_items AS oi
  INNER JOIN orders AS o ON o.order_id = oi.order_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
),
first_sale AS (
  SELECT seller_id, MIN(sale_date) AS first_sale_date
  FROM seller_sales
  GROUP BY seller_id
),
active_first_6 AS (              -- distinct selling months among months 0..5 after first sale
  SELECT ss.seller_id, COUNT(DISTINCT DATE_FORMAT(ss.sale_date, '%Y%m')) AS active_months
  FROM seller_sales AS ss
  INNER JOIN first_sale AS fs ON fs.seller_id = ss.seller_id
  WHERE PERIOD_DIFF(DATE_FORMAT(ss.sale_date, '%Y%m'),
                    DATE_FORMAT(fs.first_sale_date, '%Y%m')) BETWEEN 0 AND 5
  GROUP BY ss.seller_id
),
funnel AS (                      -- LEFT JOIN chain: a lead keeps its row even if it never converts
  SELECT l.mql_id, l.origin, l.landing_page_id, l.is_won, l.days_to_close,
         CASE WHEN fs.seller_id IS NOT NULL THEN 1 ELSE 0 END                   AS made_first_sale,
         CASE WHEN COALESCE(af.active_months, 0) >= 3 THEN 1 ELSE 0 END         AS active_3_of_6
  FROM seller_leads AS l
  LEFT JOIN first_sale     AS fs ON fs.seller_id = l.seller_id    -- NULL seller_id (not won) -> no match
  LEFT JOIN active_first_6 AS af ON af.seller_id = l.seller_id
),
close_ranked AS (                -- for the median days-to-close per origin (won leads only)
  SELECT origin, days_to_close,
         ROW_NUMBER() OVER (PARTITION BY origin ORDER BY days_to_close) AS rn,
         COUNT(*)     OVER (PARTITION BY origin)                       AS n
  FROM funnel
  WHERE is_won = 1
),
close_median AS (
  SELECT origin,
         AVG(CASE WHEN rn IN (FLOOR((n + 1) / 2), CEIL((n + 1) / 2)) THEN days_to_close END)
           AS median_days_to_close
  FROM close_ranked
  GROUP BY origin
),
landing_pages AS (               -- most-used landing pages per origin, as one text field
  SELECT origin,
         GROUP_CONCAT(CONCAT(LEFT(landing_page_id, 8), ' (', n_leads, ')')
                      ORDER BY n_leads DESC, landing_page_id SEPARATOR ', ') AS top_landing_pages
  FROM (SELECT origin, landing_page_id, COUNT(*) AS n_leads,
               ROW_NUMBER() OVER (PARTITION BY origin ORDER BY COUNT(*) DESC, landing_page_id) AS rn
        FROM funnel
        GROUP BY origin, landing_page_id) AS lp
  WHERE rn <= 3
  GROUP BY origin
)
SELECT f.origin,
       COUNT(*)                                                         AS mqls,
       SUM(f.is_won)                                                    AS won,
       SUM(f.made_first_sale)                                           AS made_first_sale,
       SUM(f.active_3_of_6)                                             AS active_3_of_first_6m,
       ROUND(100 * SUM(f.is_won) / COUNT(*), 2)                         AS mql_to_won_pct,
       ROUND(100 * SUM(f.made_first_sale) / NULLIF(SUM(f.is_won), 0), 1) AS won_to_first_sale_pct,
       ROUND(100 * SUM(f.active_3_of_6) / NULLIF(SUM(f.made_first_sale), 0), 1) AS first_sale_to_active_pct,
       ROUND(100 * SUM(f.made_first_sale) / COUNT(*), 2)                AS mql_to_first_sale_pct,
       ROUND(MAX(cm.median_days_to_close), 1)                           AS median_days_to_close,
       MAX(lp.top_landing_pages)                                        AS top_landing_pages
FROM funnel AS f
LEFT JOIN close_median  AS cm ON cm.origin = f.origin
LEFT JOIN landing_pages AS lp ON lp.origin = f.origin
GROUP BY f.origin
ORDER BY mqls DESC;
-- Reading the result: organic_search (2,296 MQLs) and paid_search (1,586) bring most leads. paid_search
--   converts MQL -> first sale best among the large channels (6.37% vs organic 4.88%), social worst (2.30%,
--   median 30 days to close). 'unknown' origin has the highest MQL -> won rate (16.65%).

-- @query: lead_funnel_overall
WITH seller_sales AS (
  SELECT oi.seller_id, DATE(o.purchase_ts) AS sale_date
  FROM order_items AS oi
  INNER JOIN orders AS o ON o.order_id = oi.order_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
),
first_sale AS (
  SELECT seller_id, MIN(sale_date) AS first_sale_date FROM seller_sales GROUP BY seller_id
),
active_first_6 AS (
  SELECT ss.seller_id, COUNT(DISTINCT DATE_FORMAT(ss.sale_date, '%Y%m')) AS active_months
  FROM seller_sales AS ss
  INNER JOIN first_sale AS fs ON fs.seller_id = ss.seller_id
  WHERE PERIOD_DIFF(DATE_FORMAT(ss.sale_date, '%Y%m'),
                    DATE_FORMAT(fs.first_sale_date, '%Y%m')) BETWEEN 0 AND 5
  GROUP BY ss.seller_id
),
totals AS (
  SELECT COUNT(*)                                                       AS mqls,
         SUM(l.is_won)                                                  AS won,
         SUM(CASE WHEN fs.seller_id IS NOT NULL THEN 1 ELSE 0 END)      AS first_sale,
         SUM(CASE WHEN COALESCE(af.active_months, 0) >= 3 THEN 1 ELSE 0 END) AS active_3_of_6
  FROM seller_leads AS l
  LEFT JOIN first_sale     AS fs ON fs.seller_id = l.seller_id
  LEFT JOIN active_first_6 AS af ON af.seller_id = l.seller_id
),
stages (stage_order, stage, sellers) AS (
  SELECT 1, 'MQL (marketing-qualified lead)', mqls FROM totals UNION ALL
  SELECT 2, 'won (contract signed)',          won FROM totals UNION ALL
  SELECT 3, 'made a first sale',              first_sale FROM totals UNION ALL
  SELECT 4, 'active in >= 3 of first 6 months', active_3_of_6 FROM totals
)
SELECT stage_order, stage, sellers,
       ROUND(100 * sellers / FIRST_VALUE(sellers) OVER (ORDER BY stage_order), 2) AS pct_of_mqls,
       ROUND(100 * sellers / LAG(sellers) OVER (ORDER BY stage_order), 1)          AS step_conversion_pct
FROM stages
ORDER BY stage_order;
-- Reading the result: 8,000 MQLs -> 842 signed (10.53%) -> 379 made a first sale (45.0% of signed) -> 182
--   active in 3+ of their first 6 months (2.28% of MQLs). The biggest leak is after signing: 55% of signed
--   sellers never sell in the window.

-- @query: won_seller_value_by_origin
WITH seller_sales AS (
  SELECT oi.seller_id, DATE(o.purchase_ts) AS sale_date, oi.price + oi.freight_value AS item_gmv
  FROM order_items AS oi
  INNER JOIN orders AS o ON o.order_id = oi.order_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
),
first_sale AS (
  SELECT seller_id, MIN(sale_date) AS first_sale_date FROM seller_sales GROUP BY seller_id
),
gmv_90d AS (                     -- GMV in the 90 days that start with the first sale
  SELECT ss.seller_id, SUM(ss.item_gmv) AS gmv_first_90d
  FROM seller_sales AS ss
  INNER JOIN first_sale AS fs ON fs.seller_id = ss.seller_id
  WHERE ss.sale_date < fs.first_sale_date + INTERVAL 90 DAY
  GROUP BY ss.seller_id
)
SELECT l.origin,
       COUNT(*)                                                           AS won_sellers,
       SUM(CASE WHEN g.seller_id IS NOT NULL THEN 1 ELSE 0 END)           AS sellers_with_sales,
       ROUND(SUM(COALESCE(g.gmv_first_90d, 0)), 2)                        AS gmv_first_90d_total_brl,
       ROUND(SUM(COALESCE(g.gmv_first_90d, 0)) / COUNT(*), 2)             AS gmv_90d_per_won_seller_brl,
       ROUND(AVG(g.gmv_first_90d), 2)                                     AS gmv_90d_per_selling_seller_brl,
       ROUND(AVG(l.days_to_close), 1)                                     AS avg_days_to_close
FROM seller_leads AS l
LEFT JOIN gmv_90d AS g ON g.seller_id = l.seller_id
WHERE l.is_won = 1
GROUP BY l.origin
ORDER BY gmv_90d_per_won_seller_brl DESC;
-- Reading the result: first-90-day GMV per signed seller is highest for unknown (R$935.50), organic_search
--   (R$736.06) and paid_search (R$704.93); social (R$536.98) and direct_traffic (R$415.99) trail. 'other' (4
--   wins) and display (6 wins) are too small to rank.
