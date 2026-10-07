/* ============================================================================
   File        : a13_rfm_segmentation.sql
   Purpose     : RFM (Recency, Frequency, Monetary) segmentation of customers, plus each
                 repeat customer's first vs latest purchased category.
   Business Q  : Who are the most valuable customers?
   SQL concepts: NTILE(5) for R and M, why NTILE fails for F (97% of people buy once ->
                 F is used as 1 vs 2+), CASE segment mapping, FIRST_VALUE / LAST_VALUE with an
                 explicit ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING frame,
                 SUM() OVER () for shares, UNION ALL total row
   Output      : rfm_segments_summary, customer_first_last_category
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/analysis/a13_rfm_segmentation.sql
   ========================================================================== */

SET @ws      = CAST(fn_cfg('window_start') AS DATE);
SET @we      = CAST(fn_cfg('window_end') AS DATE);
SET @we_excl = @we + INTERVAL 1 DAY;

-- @query: rfm_segments_summary
WITH order_values AS (           -- one row per valid order with its GMV
  SELECT o.order_id, c.customer_unique_id, o.purchase_ts,
         SUM(oi.price + oi.freight_value) AS order_gmv
  FROM orders AS o
  INNER JOIN customers   AS c  ON c.customer_id = o.customer_id
  INNER JOIN order_items AS oi ON oi.order_id   = o.order_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
  GROUP BY o.order_id, c.customer_unique_id, o.purchase_ts
),
rfm_base AS (                    -- raw R, F, M per person
  SELECT customer_unique_id,
         DATEDIFF(@we, MAX(purchase_ts)) AS recency_days,
         COUNT(*)                        AS frequency,
         SUM(order_gmv)                  AS monetary
  FROM order_values
  GROUP BY customer_unique_id
),
scored AS (
  SELECT b.customer_unique_id, b.recency_days, b.frequency, b.monetary,
         -- R: 5 = most recent fifth. Ties broken by id so the split is reproducible.
         NTILE(5) OVER (ORDER BY recency_days DESC, customer_unique_id) AS r_score,
         -- F: NTILE would scatter thousands of identical frequency=1 customers across
         -- buckets 1-4 purely by tie order, so F is a simple flag: 1 order vs 2+ orders.
         CASE WHEN frequency >= 2 THEN 2 ELSE 1 END                     AS f_score,
         NTILE(5) OVER (ORDER BY monetary, customer_unique_id)          AS m_score
  FROM rfm_base AS b
),
segmented AS (                   -- same mapping as v_dim_customer.rfm_segment
  SELECT s.customer_unique_id, s.recency_days, s.frequency, s.monetary, s.r_score, s.f_score, s.m_score,
         CASE
           WHEN f_score = 2 AND r_score >= 4  THEN 'Champions'
           WHEN f_score = 2                   THEN 'Loyal - lapsing'
           WHEN r_score >= 4 AND m_score >= 4 THEN 'New - high value'
           WHEN r_score >= 4                  THEN 'New - low value'
           WHEN m_score >= 4                  THEN 'At risk - high value'
           WHEN r_score = 1                   THEN 'Lost'
           ELSE 'Hibernating'
         END AS rfm_segment
  FROM scored AS s
)
SELECT rfm_segment,
       COUNT(*)                                                   AS customers,
       ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)           AS pct_customers,
       ROUND(AVG(recency_days), 0)                                AS avg_recency_days,
       ROUND(AVG(frequency), 2)                                   AS avg_orders,
       ROUND(AVG(monetary), 2)                                    AS avg_monetary_brl,
       ROUND(SUM(monetary), 2)                                    AS total_gmv_brl,
       ROUND(100 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 2) AS pct_gmv
FROM segmented
GROUP BY rfm_segment
UNION ALL
SELECT 'ALL CUSTOMERS', COUNT(*), 100.00, ROUND(AVG(recency_days), 0), ROUND(AVG(frequency), 2),
       ROUND(AVG(monetary), 2), ROUND(SUM(monetary), 2), 100.00
FROM segmented
ORDER BY total_gmv_brl DESC;
-- Reading the result: only 3.03% of customers have 2+ orders (Champions 1.29% + Loyal - lapsing 1.74%), so
--   value is about spend and recency. 'At risk - high value' (22.17% of customers: one big order, last seen
--   336 days before window end on average) holds 40.06% of GMV. Champions hold just 2.52%.

-- @query: customer_first_last_category
WITH item_history AS (           -- every item a repeat customer bought, in time order
  SELECT c.customer_unique_id, o.order_id, o.purchase_ts, oi.order_item_id, p.category_en
  FROM orders AS o
  INNER JOIN customers   AS c  ON c.customer_id = o.customer_id
  INNER JOIN order_items AS oi ON oi.order_id   = o.order_id
  INNER JOIN products    AS p  ON p.product_id  = oi.product_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
),
with_first_last AS (
  SELECT customer_unique_id,
         -- (MySQL does not support COUNT(DISTINCT ...) OVER (...); order counts come from order_counts)
         FIRST_VALUE(category_en) OVER w                                  AS first_category,
         -- LAST_VALUE needs the explicit frame: with ORDER BY, the DEFAULT frame ends at the
         -- CURRENT ROW, so LAST_VALUE would just return the current row's own category.
         LAST_VALUE(category_en)  OVER w                                  AS latest_category
  FROM item_history
  WINDOW w AS (PARTITION BY customer_unique_id
               ORDER BY purchase_ts, order_id, order_item_id
               ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
),
per_customer AS (
  SELECT DISTINCT customer_unique_id, first_category, latest_category
  FROM with_first_last
),
order_counts AS (
  SELECT customer_unique_id, COUNT(DISTINCT order_id) AS n_orders
  FROM item_history
  GROUP BY customer_unique_id
)
SELECT pc.customer_unique_id,
       oc.n_orders,
       pc.first_category,
       pc.latest_category,
       CASE WHEN pc.first_category = pc.latest_category THEN 1 ELSE 0 END AS same_category
FROM per_customer AS pc
INNER JOIN order_counts AS oc ON oc.customer_unique_id = pc.customer_unique_id
WHERE oc.n_orders >= 2
ORDER BY oc.n_orders DESC, pc.customer_unique_id
LIMIT 50;
-- Reading the result: among the 50 heaviest repeat buyers (up to 16 orders), only 34% bought the same
--   category first and last. LAST_VALUE works only because the frame is UNBOUNDED FOLLOWING.
