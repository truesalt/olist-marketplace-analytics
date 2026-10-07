/* ============================================================================
   File        : a15_order_status_funnel.sql
   Purpose     : Operational funnel from purchase to review: how many orders reach each
                 stage, where they drop out, and how long each stage takes.
   Business Q  : Where do orders get stuck between purchase and review?
   SQL concepts: cumulative stage flags with CASE, conditional aggregation, unpivot via
                 UNION ALL, LAG for step conversion, TIMESTAMPDIFF, window median per stage,
                 month-level funnel via conditional aggregation
   Output      : order_funnel_overall, order_funnel_monthly, stage_durations
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/analysis/a15_order_status_funnel.sql
   ========================================================================== */

SET @ws      = CAST(fn_cfg('window_start') AS DATE);
SET @we_excl = CAST(fn_cfg('window_end') AS DATE) + INTERVAL 1 DAY;

-- @query: order_funnel_overall
WITH order_stages AS (           -- ALL orders purchased in the window (canceled ones included)
  SELECT o.order_id,
         1                                                                  AS s1_purchased,
         CASE WHEN o.approved_ts IS NOT NULL THEN 1 ELSE 0 END              AS s2_approved,
         CASE WHEN o.approved_ts IS NOT NULL AND o.carrier_ts IS NOT NULL
              THEN 1 ELSE 0 END                                             AS s3_to_carrier,
         CASE WHEN o.approved_ts IS NOT NULL AND o.carrier_ts IS NOT NULL
               AND o.order_status = 'delivered' AND o.delivered_ts IS NOT NULL
              THEN 1 ELSE 0 END                                             AS s4_delivered,
         CASE WHEN o.approved_ts IS NOT NULL AND o.carrier_ts IS NOT NULL
               AND o.order_status = 'delivered' AND o.delivered_ts IS NOT NULL
               AND r.order_id IS NOT NULL
              THEN 1 ELSE 0 END                                             AS s5_reviewed
  FROM orders AS o
  LEFT JOIN order_reviews AS r ON r.order_id = o.order_id
  WHERE o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
),
totals AS (
  SELECT SUM(s1_purchased) AS s1, SUM(s2_approved) AS s2, SUM(s3_to_carrier) AS s3,
         SUM(s4_delivered) AS s4, SUM(s5_reviewed) AS s5
  FROM order_stages
),
unpivoted (stage_order, stage, orders) AS (    -- columns -> rows
  SELECT 1, 'purchased', s1 FROM totals UNION ALL
  SELECT 2, 'payment approved', s2 FROM totals UNION ALL
  SELECT 3, 'handed to carrier', s3 FROM totals UNION ALL
  SELECT 4, 'delivered to customer', s4 FROM totals UNION ALL
  SELECT 5, 'reviewed', s5 FROM totals
)
SELECT stage_order,
       stage,
       orders,
       ROUND(100 * orders / FIRST_VALUE(orders) OVER (ORDER BY stage_order), 2)          AS pct_of_purchased,
       ROUND(100 * orders / LAG(orders) OVER (ORDER BY stage_order), 2)                AS step_conversion_pct,
       LAG(orders) OVER (ORDER BY stage_order) - orders                                  AS lost_at_this_step
FROM unpivoted
ORDER BY stage_order;
-- Reading the result: of 99,092 orders placed in the window, 99.86% were approved, 98.25% reached a carrier,
--   97.07% were delivered and 96.42% reviewed. The biggest single drop is approval -> carrier hand-off (1,595
--   orders).

-- @query: order_funnel_monthly
WITH order_stages AS (
  SELECT DATE_FORMAT(o.purchase_ts, '%Y-%m')                                AS ym,
         CASE WHEN o.approved_ts IS NOT NULL THEN 1 ELSE 0 END              AS approved,
         CASE WHEN o.approved_ts IS NOT NULL AND o.carrier_ts IS NOT NULL
              THEN 1 ELSE 0 END                                             AS to_carrier,
         CASE WHEN o.approved_ts IS NOT NULL AND o.carrier_ts IS NOT NULL
               AND o.order_status = 'delivered' AND o.delivered_ts IS NOT NULL
              THEN 1 ELSE 0 END                                             AS delivered,
         CASE WHEN o.approved_ts IS NOT NULL AND o.carrier_ts IS NOT NULL
               AND o.order_status = 'delivered' AND o.delivered_ts IS NOT NULL
               AND r.order_id IS NOT NULL THEN 1 ELSE 0 END                 AS reviewed,
         CASE WHEN o.order_status IN ('canceled', 'unavailable') THEN 1 ELSE 0 END AS canceled_or_unavailable
  FROM orders AS o
  LEFT JOIN order_reviews AS r ON r.order_id = o.order_id
  WHERE o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
)
SELECT ym                                                    AS `year_month`,
       COUNT(*)                                              AS purchased,
       ROUND(100 * AVG(approved), 2)                         AS approved_pct,
       ROUND(100 * AVG(to_carrier), 2)                       AS to_carrier_pct,
       ROUND(100 * AVG(delivered), 2)                        AS delivered_pct,
       ROUND(100 * AVG(reviewed), 2)                         AS reviewed_pct,
       ROUND(100 * AVG(canceled_or_unavailable), 2)          AS canceled_or_unavailable_pct
FROM order_stages
GROUP BY ym
ORDER BY ym;
-- Reading the result: cancellation/unavailability peaked early (3.48% in Feb-2017) and fell below 1% in most
--   of 2018; the delivered share rose from 92.19% (Feb-2017) to 97-99% in 2018.

-- @query: stage_durations
WITH clean_deliveries AS (       -- valid deliveries only: all timestamps present and in order
  SELECT o.purchase_ts, o.approved_ts, o.carrier_ts, o.delivered_ts, r.review_created_date
  FROM orders AS o
  LEFT JOIN order_reviews AS r ON r.order_id = o.order_id
  WHERE o.is_valid_delivery = 1
    AND o.approved_ts IS NOT NULL
    AND o.carrier_ts IS NOT NULL
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
),
stage_hours (stage_order, stage, hours) AS (   -- one row per order per stage
  SELECT 1, 'purchase -> payment approved', TIMESTAMPDIFF(HOUR, purchase_ts, approved_ts)
    FROM clean_deliveries
  UNION ALL
  SELECT 2, 'approved -> handed to carrier', TIMESTAMPDIFF(HOUR, approved_ts, carrier_ts)
    FROM clean_deliveries
  UNION ALL
  SELECT 3, 'carrier -> delivered', TIMESTAMPDIFF(HOUR, carrier_ts, delivered_ts) FROM clean_deliveries
  UNION ALL
  SELECT 4, 'purchase -> delivered (total)', TIMESTAMPDIFF(HOUR, purchase_ts, delivered_ts)
    FROM clean_deliveries
  UNION ALL
  -- review_created_date is a DATE (no time), so compare whole days (x 24 to stay in hours).
  -- Negative = the review survey was created BEFORE the parcel arrived (happens on late orders).
  SELECT 5, 'delivered date -> review created date', 24 * DATEDIFF(review_created_date, DATE(delivered_ts))
  FROM clean_deliveries WHERE review_created_date IS NOT NULL
),
ranked AS (
  SELECT sh.stage_order, sh.stage, sh.hours,
         ROW_NUMBER() OVER (PARTITION BY stage_order ORDER BY hours) AS rn,
         COUNT(*)     OVER (PARTITION BY stage_order)                AS n
  FROM stage_hours AS sh
)
SELECT stage_order,
       stage,
       MAX(n)                                                                  AS orders_measured,
       ROUND(AVG(hours), 1)                                                    AS avg_hours,
       ROUND(AVG(CASE WHEN rn IN (FLOOR((n + 1) / 2), CEIL((n + 1) / 2)) THEN hours END), 1) AS median_hours,
       ROUND(AVG(hours) / 24, 2)                                               AS avg_days
FROM ranked
GROUP BY stage_order, stage
ORDER BY stage_order;
-- Reading the result: for 94,819 clean deliveries the 12.58-day average splits into 0.39 days to approve
--   payment (median 0 h), 2.80 days for the seller to hand the parcel to the carrier (median 44 h) and 9.35
--   days in transit (median 170 h). Transit is ~3/4 of lead time; seller handling is the most controllable
--   leg. Reviews are created 0.45 days after delivery on average (median 1 day).
