/* ============================================================================
   File        : a05_delay_vs_review.sql
   Purpose     : Review-score distribution for each delay bucket (early / on time / late).
   Business Q  : Q3 - How does lateness change review scores?
   SQL concepts: stored function in SELECT/GROUP BY (fn_delay_bucket), CASE pivot of scores
                 1-5 into columns, percentages with NULLIF, conditional aggregation
   Output      : review_by_delay_bucket
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/analysis/a05_delay_vs_review.sql
   ========================================================================== */

SET @ws      = CAST(fn_cfg('window_start') AS DATE);
SET @we_excl = CAST(fn_cfg('window_end') AS DATE) + INTERVAL 1 DAY;
SET @low_max = CAST(fn_cfg('low_review_max') AS UNSIGNED);

-- @query: review_by_delay_bucket
WITH reviewed_orders AS (        -- valid orders that have a review; bucket from delay_days
  SELECT fn_delay_bucket(o.delay_days) AS delay_bucket,   -- NULL delay -> 'Not delivered'
         r.review_score
  FROM orders AS o
  INNER JOIN order_reviews AS r ON r.order_id = o.order_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws
    AND o.purchase_ts <  @we_excl
    AND EXISTS (SELECT 1 FROM order_items AS oi WHERE oi.order_id = o.order_id)
)
SELECT delay_bucket,
       COUNT(*)                                                               AS reviewed_orders,
       ROUND(AVG(review_score), 2)                                            AS avg_score,
       -- CASE pivot: one column per score, as % of the bucket's reviews
       ROUND(100 * SUM(CASE WHEN review_score = 1 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0), 1) AS score_1_pct,
       ROUND(100 * SUM(CASE WHEN review_score = 2 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0), 1) AS score_2_pct,
       ROUND(100 * SUM(CASE WHEN review_score = 3 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0), 1) AS score_3_pct,
       ROUND(100 * SUM(CASE WHEN review_score = 4 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0), 1) AS score_4_pct,
       ROUND(100 * SUM(CASE WHEN review_score = 5 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0), 1) AS score_5_pct,
       ROUND(100 * SUM(CASE WHEN review_score <= @low_max THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0), 1)
                                                                              AS low_review_pct
FROM reviewed_orders
GROUP BY delay_bucket
ORDER BY delay_bucket;           -- numeric prefixes sort buckets in delay order
-- Reading the result: the review penalty is steep and monotonic. Low reviews (1-2 stars): 9.0% when delivered
--   7+ days early, 10.8% on time, 32.3% at 1-3 days late, 67.7% at 4-7 days, 79.3% at 8+ days late; the
--   average score falls from 4.31 to 1.70. The 2,980 reviewed orders with no valid delivery ('Not delivered')
--   average 2.95 with 45.8% low reviews.
