/* ============================================================================
   File        : 09_star_schema_views.sql
   Purpose     : Build the analysis-friendly star schema used by Power BI and many
                 analyses: a dim_date table (recursive CTE) plus dimension and fact views.
   Business Q  : setup (one consistent definition of "valid order", GMV, repeat, etc.)
   SQL concepts: recursive CTE (date spine), cte_max_recursion_depth, CREATE OR REPLACE VIEW,
                 chained CTEs, pre-aggregation to avoid fan-out, ROW_NUMBER / NTILE / MAX() OVER,
                 conditional aggregation (cfg pivot), LEFT/INNER JOIN, ST_Distance_Sphere,
                 PERIOD_DIFF, DATE_FORMAT, WEEKDAY, CASE, COALESCE
   Output      : table dim_date; views v_valid_orders (order grain helper), v_fact_order_items
                 (main fact, item grain), v_dim_customer, v_dim_seller, v_dim_product,
                 v_fact_seller_leads
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/setup/09_star_schema_views.sql
   ========================================================================== */

USE olist;

-- Default limit is 1000 recursion steps; the calendar below needs ~850 (one per day).
SET SESSION cte_max_recursion_depth = 5000;

-- ---------------------------------------------------------------------------
-- dim_date: a real TABLE (not a view) so Power BI can mark it as the date table.
-- in_window is computed once here from cfg_params; views filter on it instead of
-- re-reading the config for every order row.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS dim_date;
CREATE TABLE dim_date (
  `date`          DATE        NOT NULL,
  `year`          SMALLINT    NOT NULL,
  `quarter`       TINYINT     NOT NULL,
  month_num       TINYINT     NOT NULL,
  month_name      VARCHAR(9)  NOT NULL,
  month_start     DATE        NOT NULL,
  `year_month`    CHAR(7)     NOT NULL,   -- backticks: YEAR_MONTH is a reserved word in MySQL
  week_start      DATE        NOT NULL,   -- Monday of the ISO week
  day_of_week_num TINYINT     NOT NULL,   -- 1 = Monday ... 7 = Sunday
  day_name        VARCHAR(9)  NOT NULL,
  is_weekend      BOOLEAN     NOT NULL,
  in_window       BOOLEAN     NOT NULL,   -- between cfg window_start and window_end
  PRIMARY KEY (`date`)
) COMMENT = 'Calendar 2016-09-01..2018-12-31 built with a recursive CTE (Power BI date table)';

INSERT INTO dim_date (`date`, `year`, `quarter`, month_num, month_name, month_start, `year_month`,
                      week_start, day_of_week_num, day_name, is_weekend, in_window)
WITH RECURSIVE calendar (d) AS (
  SELECT DATE '2016-09-01'                         -- anchor: first day of the data
  UNION ALL
  SELECT d + INTERVAL 1 DAY                        -- recursive step: next day
  FROM calendar
  WHERE d < DATE '2018-12-31'                      -- stop condition
),
params AS (
  SELECT CAST(fn_cfg('window_start') AS DATE) AS window_start,
         CAST(fn_cfg('window_end')   AS DATE) AS window_end
)
SELECT
  c.d,
  YEAR(c.d),
  QUARTER(c.d),
  MONTH(c.d),
  MONTHNAME(c.d),
  CAST(DATE_FORMAT(c.d, '%Y-%m-01') AS DATE),
  DATE_FORMAT(c.d, '%Y-%m'),
  c.d - INTERVAL WEEKDAY(c.d) DAY,                 -- WEEKDAY: Monday = 0
  WEEKDAY(c.d) + 1,
  DAYNAME(c.d),
  WEEKDAY(c.d) >= 5,                               -- Saturday or Sunday
  c.d BETWEEN p.window_start AND p.window_end
FROM calendar AS c
CROSS JOIN params AS p;

-- ---------------------------------------------------------------------------
-- v_valid_orders: helper at ORDER grain. The single place where "valid order" is
-- defined: status not canceled/unavailable, purchased inside the window, >= 1 item.
-- Items and payments are each pre-aggregated to one row per order BEFORE joining,
-- so nothing is double counted (see a07_fanout_trap.sql).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_valid_orders AS
WITH params AS (                 -- cfg_params pivoted into one row (aggregate -> computed once)
  SELECT MAX(CASE WHEN param_name = 'low_review_max' THEN CAST(param_value AS UNSIGNED) END)
           AS low_review_max
  FROM cfg_params
),
item_totals AS (                 -- items -> one row per order
  SELECT order_id,
         COUNT(*)                   AS n_items,
         SUM(price)                 AS merchandise_value,
         SUM(freight_value)         AS freight_value,
         SUM(price + freight_value) AS order_gmv
  FROM order_items
  GROUP BY order_id
),
payment_ranked AS (              -- payments -> order-level attributes via window functions
  SELECT order_id,
         payment_type,
         ROW_NUMBER() OVER (PARTITION BY order_id
                            ORDER BY payment_value DESC, payment_sequential)          AS rn,
         MAX(CASE WHEN payment_type = 'voucher' THEN 1 ELSE 0 END)
           OVER (PARTITION BY order_id)                                               AS has_voucher,
         MAX(payment_installments) OVER (PARTITION BY order_id)                       AS max_installments
  FROM order_payments
)
SELECT
  o.order_id,
  o.customer_id,
  c.customer_unique_id,
  o.order_status,
  o.purchase_ts,
  DATE(o.purchase_ts)                                  AS purchase_date,
  o.estimated_date,
  o.delivered_ts,
  o.is_valid_delivery,
  o.is_late,
  o.delivery_days,
  o.delay_days,
  fn_delay_bucket(o.delay_days)                        AS delay_bucket,
  r.review_score,
  CASE WHEN r.review_score IS NULL              THEN NULL
       WHEN r.review_score <= p.low_review_max  THEN 1
       ELSE 0 END                                      AS is_low_review,
  COALESCE(pr.has_voucher, 0)                          AS has_voucher,
  pr.payment_type                                      AS payment_type_main,  -- largest payment
  pr.max_installments,
  it.n_items,
  it.merchandise_value,
  it.freight_value,
  it.order_gmv
FROM orders AS o
INNER JOIN customers       AS c  ON c.customer_id = o.customer_id
INNER JOIN dim_date        AS d  ON d.`date` = DATE(o.purchase_ts)
INNER JOIN item_totals     AS it ON it.order_id = o.order_id     -- drops the 5 item-less orders
LEFT JOIN  payment_ranked  AS pr ON pr.order_id = o.order_id
                                AND pr.rn = 1
LEFT JOIN  order_reviews   AS r  ON r.order_id = o.order_id
CROSS JOIN params          AS p
WHERE o.order_status NOT IN ('canceled', 'unavailable')
  AND d.in_window = 1;

-- ---------------------------------------------------------------------------
-- v_fact_order_items: THE fact table (grain = one order item).
-- Order-level attributes (delivery, review, payment) are denormalised onto every item so
-- one fact can be sliced by seller, product, customer and date. Order-level measures must
-- therefore count DISTINCT order_id (DAX: DISTINCTCOUNT).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_fact_order_items AS
SELECT
  oi.order_id,
  oi.order_item_id,
  vo.purchase_date,
  vo.customer_unique_id,
  oi.seller_id,
  oi.product_id,
  oi.price,
  oi.freight_value,
  oi.price + oi.freight_value                          AS item_gmv,
  vo.order_status,
  vo.is_valid_delivery,
  vo.is_late,
  vo.delivery_days,
  vo.delay_days,
  vo.delay_bucket,
  vo.review_score,
  vo.is_low_review,
  vo.has_voucher,
  vo.payment_type_main,
  vo.max_installments,
  -- great-circle distance seller zip -> customer zip; POINT takes (longitude, latitude)
  ROUND(ST_Distance_Sphere(POINT(sg.lng, sg.lat), POINT(cg.lng, cg.lat)) / 1000, 1) AS distance_km,
  s.region                                             AS seller_region,
  c.region                                             AS customer_region
FROM order_items AS oi
INNER JOIN v_valid_orders  AS vo ON vo.order_id = oi.order_id
INNER JOIN sellers         AS s  ON s.seller_id = oi.seller_id
INNER JOIN customers       AS c  ON c.customer_id = vo.customer_id
LEFT JOIN  geolocation_zip AS sg ON sg.zip_prefix = s.zip_prefix   -- 7 seller zips have no geo
LEFT JOIN  geolocation_zip AS cg ON cg.zip_prefix = c.zip_prefix;  -- 278 customer rows have no geo

-- ---------------------------------------------------------------------------
-- v_dim_customer: one row per PERSON (customer_unique_id) with first-order facts,
-- repeat flags and RFM segment.
--   eligible_repeat = first order on/before window_end - repeat_horizon_days, so every
--                     eligible customer had a full 180 days to come back (no right-censoring)
--   repeat_180d     = a later-calendar-day valid order within 180 days of the first order
--                     (same-day extra checkouts happen before delivery, so they are not
--                     "coming back" and are not counted)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_dim_customer AS
WITH params AS (
  SELECT MAX(CASE WHEN param_name = 'window_end' THEN CAST(param_value AS DATE) END)         AS window_end,
         MAX(CASE WHEN param_name = 'repeat_horizon_days' THEN CAST(param_value AS UNSIGNED) END)
           AS horizon_days
  FROM cfg_params
),
customer_orders AS (             -- every valid order, numbered per person in time order
  SELECT vo.customer_unique_id, vo.customer_id, vo.order_id, vo.purchase_ts,
         vo.is_late, vo.has_voucher, vo.order_gmv,
         ROW_NUMBER() OVER (PARTITION BY vo.customer_unique_id
                            ORDER BY vo.purchase_ts, vo.order_id) AS order_seq
  FROM v_valid_orders AS vo
),
first_orders AS (
  SELECT customer_unique_id, customer_id, order_id, purchase_ts, is_late, has_voucher, order_gmv
  FROM customer_orders
  WHERE order_seq = 1
),
next_day_orders AS (             -- earliest order on a LATER calendar day than the first order
  SELECT co.customer_unique_id, MIN(co.purchase_ts) AS second_order_ts
  FROM customer_orders AS co
  INNER JOIN first_orders AS fo ON fo.customer_unique_id = co.customer_unique_id
  WHERE DATE(co.purchase_ts) > DATE(fo.purchase_ts)
  GROUP BY co.customer_unique_id
),
customer_totals AS (
  SELECT customer_unique_id,
         COUNT(*)         AS total_orders,
         SUM(order_gmv)   AS total_gmv,
         MAX(purchase_ts) AS last_order_ts
  FROM customer_orders
  GROUP BY customer_unique_id
),
rfm_scores AS (                  -- same scoring as a13_rfm_segmentation.sql
  SELECT ct.customer_unique_id,
         NTILE(5) OVER (ORDER BY DATEDIFF(p.window_end, ct.last_order_ts) DESC,
                                 ct.customer_unique_id)          AS r_score,  -- 5 = most recent
         CASE WHEN ct.total_orders >= 2 THEN 2 ELSE 1 END        AS f_score,  -- 97% buy once
         NTILE(5) OVER (ORDER BY ct.total_gmv, ct.customer_unique_id) AS m_score  -- 5 = top spend
  FROM customer_totals AS ct
  CROSS JOIN params AS p
)
SELECT
  fo.customer_unique_id,
  c.state,                                             -- address used on the first order
  c.region,
  c.city_clean,
  fo.purchase_ts                                       AS first_order_ts,
  DATE_FORMAT(fo.purchase_ts, '%Y-%m')                 AS first_order_month,
  fo.order_id                                          AS first_order_id,
  fo.is_late                                           AS first_order_is_late,  -- NULL: not a valid delivery
  fo.has_voucher                                       AS first_order_has_voucher,
  fo.order_gmv                                         AS first_order_value,
  ct.total_orders,
  ct.total_gmv,
  CASE WHEN DATE(fo.purchase_ts) <= p.window_end - INTERVAL p.horizon_days DAY
       THEN 1 ELSE 0 END                               AS eligible_repeat,
  CASE WHEN nd.second_order_ts IS NOT NULL
        AND DATEDIFF(nd.second_order_ts, fo.purchase_ts) <= p.horizon_days
       THEN 1 ELSE 0 END                               AS repeat_180d,
  CASE
    WHEN rs.f_score = 2 AND rs.r_score >= 4  THEN 'Champions'
    WHEN rs.f_score = 2                      THEN 'Loyal - lapsing'
    WHEN rs.r_score >= 4 AND rs.m_score >= 4 THEN 'New - high value'
    WHEN rs.r_score >= 4                     THEN 'New - low value'
    WHEN rs.m_score >= 4                     THEN 'At risk - high value'
    WHEN rs.r_score = 1                      THEN 'Lost'
    ELSE 'Hibernating'
  END                                                  AS rfm_segment
FROM first_orders AS fo
INNER JOIN customers       AS c  ON c.customer_id = fo.customer_id
INNER JOIN customer_totals AS ct ON ct.customer_unique_id = fo.customer_unique_id
INNER JOIN rfm_scores      AS rs ON rs.customer_unique_id = fo.customer_unique_id
LEFT JOIN  next_day_orders AS nd ON nd.customer_unique_id = fo.customer_unique_id
CROSS JOIN params          AS p;

-- ---------------------------------------------------------------------------
-- v_dim_seller: one row per seller (all 3,095, including sellers with no sales in window)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_dim_seller AS
WITH seller_sales AS (
  SELECT oi.seller_id,
         MIN(vo.purchase_date) AS first_sale_date,
         MAX(vo.purchase_date) AS last_sale_date
  FROM order_items AS oi
  INNER JOIN v_valid_orders AS vo ON vo.order_id = oi.order_id
  GROUP BY oi.seller_id
),
won_leads AS (                   -- seller acquired through the marketing funnel (earliest win)
  SELECT seller_id, origin,
         ROW_NUMBER() OVER (PARTITION BY seller_id ORDER BY won_date, mql_id) AS rn
  FROM seller_leads
  WHERE is_won = 1
    AND seller_id IS NOT NULL
)
SELECT
  s.seller_id,
  s.state,
  s.region,
  s.city_clean,
  DATE_FORMAT(ss.first_sale_date, '%Y-%m')             AS first_sale_month,
  DATE_FORMAT(ss.last_sale_date, '%Y-%m')              AS last_sale_month,
  wl.origin                                            AS lead_origin,
  CASE WHEN wl.seller_id IS NOT NULL THEN 1 ELSE 0 END AS is_acquired_via_funnel
FROM sellers AS s
LEFT JOIN seller_sales AS ss ON ss.seller_id = s.seller_id
LEFT JOIN won_leads    AS wl ON wl.seller_id = s.seller_id
                            AND wl.rn = 1;

-- ---------------------------------------------------------------------------
-- v_dim_product: one row per product
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_dim_product AS
SELECT
  p.product_id,
  p.category_en,
  p.weight_g,
  p.length_cm * p.height_cm * p.width_cm AS volume_cm3,
  p.photos_qty
FROM products AS p;

-- ---------------------------------------------------------------------------
-- v_fact_seller_leads: one row per marketing-qualified lead (MQL) with its funnel outcome.
-- Funnel: MQL -> won -> first sale -> active in 3+ of its first 6 months.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_fact_seller_leads AS
WITH won_seller_items AS (       -- sales of funnel-acquired sellers (CTE reused 3x, built once)
  SELECT f.seller_id, f.purchase_date, f.item_gmv
  FROM v_fact_order_items AS f
  WHERE f.seller_id IN (SELECT seller_id FROM seller_leads WHERE is_won = 1)
),
first_sale AS (
  SELECT seller_id, MIN(purchase_date) AS first_sale_date
  FROM won_seller_items
  GROUP BY seller_id
),
gmv_first_90d AS (               -- GMV in the 90 days starting at the first sale
  SELECT w.seller_id, SUM(w.item_gmv) AS gmv_first_90d
  FROM won_seller_items AS w
  INNER JOIN first_sale AS fs ON fs.seller_id = w.seller_id
  WHERE w.purchase_date < fs.first_sale_date + INTERVAL 90 DAY
  GROUP BY w.seller_id
),
active_months AS (               -- distinct selling months among the first 6 (months 0..5)
  SELECT w.seller_id, COUNT(DISTINCT DATE_FORMAT(w.purchase_date, '%Y-%m')) AS active_months_first_6
  FROM won_seller_items AS w
  INNER JOIN first_sale AS fs ON fs.seller_id = w.seller_id
  WHERE PERIOD_DIFF(DATE_FORMAT(w.purchase_date, '%Y%m'),
                    DATE_FORMAT(fs.first_sale_date, '%Y%m')) BETWEEN 0 AND 5
  GROUP BY w.seller_id
)
SELECT
  l.mql_id,
  l.first_contact_date,
  l.origin,
  l.landing_page_id,
  l.is_won,
  l.won_date,
  l.days_to_close,
  l.business_segment,
  l.lead_type,
  l.seller_id,
  fs.first_sale_date,
  CASE WHEN fs.first_sale_date IS NOT NULL THEN 1 ELSE 0 END AS made_first_sale,
  COALESCE(g.gmv_first_90d, 0)                               AS gmv_first_90d,
  COALESCE(am.active_months_first_6, 0)                      AS active_months_first_6
FROM seller_leads AS l
LEFT JOIN first_sale    AS fs ON fs.seller_id = l.seller_id
LEFT JOIN gmv_first_90d AS g  ON g.seller_id = l.seller_id
LEFT JOIN active_months AS am ON am.seller_id = l.seller_id;

-- ---------------------------------------------------------------------------
-- Sanity check: row counts of every star-schema object
-- ---------------------------------------------------------------------------
SELECT 'dim_date' AS object_name, COUNT(*) AS row_count FROM dim_date
UNION ALL SELECT 'v_valid_orders',      COUNT(*) FROM v_valid_orders
UNION ALL SELECT 'v_fact_order_items',  COUNT(*) FROM v_fact_order_items
UNION ALL SELECT 'v_dim_customer',      COUNT(*) FROM v_dim_customer
UNION ALL SELECT 'v_dim_seller',        COUNT(*) FROM v_dim_seller
UNION ALL SELECT 'v_dim_product',       COUNT(*) FROM v_dim_product
UNION ALL SELECT 'v_fact_seller_leads', COUNT(*) FROM v_fact_seller_leads;
