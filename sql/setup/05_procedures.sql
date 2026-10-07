/* ============================================================================
   File        : 05_procedures.sql
   Purpose     : Stored procedures: (1) sp_refresh_marts rebuilds every mart_* summary
                 table and logs row counts - MySQL's substitute for materialized views;
                 (2) sp_seller_scorecard returns a one-seller report for a seller_id.
                 (sp_load_core, the transactional staging->core load, lives in 06.)
   Business Q  : setup + "How is seller X doing vs its category?"
   SQL concepts: stored procedures, IN parameter, DECLARE local variables, TRUNCATE +
                 INSERT ... SELECT, WITH RECURSIVE inside INSERT, ROW_COUNT(), LAG(1)/LAG(12),
                 ROW_NUMBER/RANK/PERCENT_RANK, running SUM() OVER, window-based median,
                 PERIOD_DIFF, CASE pivot, scalar subquery
   Output      : procedures sp_refresh_marts(), sp_seller_scorecard(IN p_seller_id CHAR(32))
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/setup/05_procedures.sql
   Note        : procedure bodies are only resolved when CALLed, so this file can be created
                 before the views (09) and mart tables (10) it uses exist.
   ========================================================================== */

USE olist;

DROP PROCEDURE IF EXISTS sp_refresh_marts;
DROP PROCEDURE IF EXISTS sp_seller_scorecard;

DELIMITER $$

-- ===========================================================================
-- sp_refresh_marts(): TRUNCATE + INSERT ... SELECT for each mart, then log row counts.
-- Marts store fractions (0-1) for *_pct columns; Power BI formats them as %.
-- ===========================================================================
CREATE PROCEDURE sp_refresh_marts()
MODIFIES SQL DATA
COMMENT 'Rebuild all mart_* tables (materialized-view emulation) and log row counts'
BEGIN
  DECLARE v_ws DATE;                    -- analysis window, read once from cfg_params
  DECLARE v_we DATE;
  DECLARE v_run_ts DATETIME DEFAULT NOW();  -- one timestamp for every log row of this run
  SET v_ws = CAST(fn_cfg('window_start') AS DATE);
  SET v_we = CAST(fn_cfg('window_end') AS DATE);
  SET SESSION cte_max_recursion_depth = 5000;

  -- -------------------------------------------------------------------------
  -- 1. mart_monthly_kpis: one row per month of the window (zero-filled by a month spine)
  -- -------------------------------------------------------------------------
  TRUNCATE TABLE mart_monthly_kpis;
  INSERT INTO mart_monthly_kpis
    (`year_month`, gmv, orders, customers, aov, on_time_pct, low_review_pct, new_customers,
     gmv_mom_pct, gmv_yoy_pct)
  WITH RECURSIVE month_spine (month_start) AS (
    SELECT CAST(DATE_FORMAT(v_ws, '%Y-%m-01') AS DATE)
    UNION ALL
    SELECT month_start + INTERVAL 1 MONTH
    FROM month_spine
    WHERE month_start + INTERVAL 1 MONTH <= v_we
  ),
  orders_by_month AS (
    SELECT DATE_FORMAT(purchase_date, '%Y-%m')                     AS ym,
           SUM(order_gmv)                                          AS gmv,
           COUNT(*)                                                AS orders,
           COUNT(DISTINCT customer_unique_id)                      AS customers,
           SUM(is_valid_delivery)                                  AS valid_deliveries,
           SUM(CASE WHEN is_late = 1 THEN 1 ELSE 0 END)            AS late_orders,
           SUM(CASE WHEN review_score IS NOT NULL THEN 1 ELSE 0 END) AS reviewed_orders,
           SUM(CASE WHEN is_low_review = 1 THEN 1 ELSE 0 END)      AS low_review_orders
    FROM v_valid_orders
    GROUP BY DATE_FORMAT(purchase_date, '%Y-%m')
  ),
  first_month AS (                     -- month of each customer's first valid order
    SELECT customer_unique_id, DATE_FORMAT(MIN(purchase_date), '%Y-%m') AS ym
    FROM v_valid_orders
    GROUP BY customer_unique_id
  ),
  new_by_month AS (
    SELECT ym, COUNT(*) AS new_customers
    FROM first_month
    GROUP BY ym
  ),
  monthly AS (                          -- LEFT JOIN from the spine: empty months show 0
    SELECT DATE_FORMAT(ms.month_start, '%Y-%m') AS ym,
           COALESCE(obm.gmv, 0)                 AS gmv,
           COALESCE(obm.orders, 0)              AS orders,
           COALESCE(obm.customers, 0)           AS customers,
           obm.valid_deliveries, obm.late_orders, obm.reviewed_orders, obm.low_review_orders,
           COALESCE(nbm.new_customers, 0)       AS new_customers
    FROM month_spine AS ms
    LEFT JOIN orders_by_month AS obm ON obm.ym = DATE_FORMAT(ms.month_start, '%Y-%m')
    LEFT JOIN new_by_month    AS nbm ON nbm.ym = DATE_FORMAT(ms.month_start, '%Y-%m')
  )
  SELECT ym,
         gmv,
         orders,
         customers,
         ROUND(gmv / NULLIF(orders, 0), 2)                               AS aov,
         ROUND(1 - late_orders / NULLIF(valid_deliveries, 0), 4)         AS on_time_pct,
         ROUND(low_review_orders / NULLIF(reviewed_orders, 0), 4)        AS low_review_pct,
         new_customers,
         ROUND((gmv - LAG(gmv, 1) OVER w) / NULLIF(LAG(gmv, 1) OVER w, 0), 4)   AS gmv_mom_pct,
         ROUND((gmv - LAG(gmv, 12) OVER w) / NULLIF(LAG(gmv, 12) OVER w, 0), 4) AS gmv_yoy_pct
  FROM monthly
  WINDOW w AS (ORDER BY ym);
  INSERT INTO mart_refresh_log (refreshed_at, mart_name, row_count)
  VALUES (v_run_ts, 'mart_monthly_kpis', ROW_COUNT());

  -- -------------------------------------------------------------------------
  -- 2. mart_lane_sla: delivery SLA per seller-state -> customer-state lane.
  --    An order with sellers in two states counts once in each lane.
  -- -------------------------------------------------------------------------
  TRUNCATE TABLE mart_lane_sla;
  INSERT INTO mart_lane_sla
    (seller_region, customer_region, seller_state, customer_state, delivered_orders,
     late_orders, late_pct, avg_delivery_days, median_delivery_days)
  WITH order_lanes AS (
    SELECT DISTINCT vo.order_id,
           s.region AS seller_region, s.state AS seller_state,
           c.region AS customer_region, c.state AS customer_state,
           vo.is_late, vo.delivery_days
    FROM v_valid_orders AS vo
    INNER JOIN customers   AS c  ON c.customer_id = vo.customer_id
    INNER JOIN order_items AS oi ON oi.order_id = vo.order_id
    INNER JOIN sellers     AS s  ON s.seller_id = oi.seller_id
    WHERE vo.is_valid_delivery = 1
  ),
  ranked AS (                           -- median helper: row position + lane size
    SELECT ol.*,
           ROW_NUMBER() OVER (PARTITION BY seller_state, customer_state ORDER BY delivery_days) AS rn,
           COUNT(*)     OVER (PARTITION BY seller_state, customer_state)                        AS n
    FROM order_lanes AS ol
  )
  SELECT seller_region, customer_region, seller_state, customer_state,
         COUNT(*)                                   AS delivered_orders,
         SUM(is_late)                               AS late_orders,
         ROUND(SUM(is_late) / COUNT(*), 4)          AS late_pct,
         ROUND(AVG(delivery_days), 2)               AS avg_delivery_days,
         -- median = average of the middle row(s): positions FLOOR((n+1)/2) and CEIL((n+1)/2)
         AVG(CASE WHEN rn IN (FLOOR((n + 1) / 2), CEIL((n + 1) / 2)) THEN delivery_days END)
                                                    AS median_delivery_days
  FROM ranked
  GROUP BY seller_region, customer_region, seller_state, customer_state;
  INSERT INTO mart_refresh_log (refreshed_at, mart_name, row_count)
  VALUES (v_run_ts, 'mart_lane_sla', ROW_COUNT());

  -- -------------------------------------------------------------------------
  -- 3. mart_cohort_retention (long format): share of each first-order-month cohort that
  --    orders again N months later. Zero-filled for every observable month.
  -- -------------------------------------------------------------------------
  TRUNCATE TABLE mart_cohort_retention;
  INSERT INTO mart_cohort_retention
    (cohort_month, months_since, active_customers, cohort_size, retention_pct)
  WITH RECURSIVE month_offsets (months_since) AS (
    SELECT 0
    UNION ALL
    SELECT months_since + 1
    FROM month_offsets
    WHERE months_since < PERIOD_DIFF(DATE_FORMAT(v_we, '%Y%m'), DATE_FORMAT(v_ws, '%Y%m'))
  ),
  customer_months AS (                  -- distinct (customer, active month) pairs
    SELECT DISTINCT customer_unique_id, DATE_FORMAT(purchase_date, '%Y%m') AS ym
    FROM v_valid_orders
  ),
  cohorts AS (                          -- cohort = month of first valid order
    SELECT customer_unique_id, MIN(ym) AS cohort_ym
    FROM customer_months
    GROUP BY customer_unique_id
  ),
  cohort_sizes AS (
    SELECT cohort_ym, COUNT(*) AS cohort_size
    FROM cohorts
    GROUP BY cohort_ym
  ),
  activity AS (                         -- active customers per cohort and month offset
    SELECT co.cohort_ym,
           PERIOD_DIFF(cm.ym, co.cohort_ym) AS months_since,
           COUNT(*)                         AS active_customers
    FROM customer_months AS cm
    INNER JOIN cohorts AS co ON co.customer_unique_id = cm.customer_unique_id
    GROUP BY co.cohort_ym, PERIOD_DIFF(cm.ym, co.cohort_ym)
  )
  SELECT CONCAT(LEFT(cs.cohort_ym, 4), '-', RIGHT(cs.cohort_ym, 2)) AS cohort_month,
         mo.months_since,
         COALESCE(a.active_customers, 0)                             AS active_customers,
         cs.cohort_size,
         ROUND(COALESCE(a.active_customers, 0) / cs.cohort_size, 4)  AS retention_pct
  FROM cohort_sizes AS cs
  INNER JOIN month_offsets AS mo                 -- only offsets that fall inside the window
          ON mo.months_since <= PERIOD_DIFF(DATE_FORMAT(v_we, '%Y%m'), cs.cohort_ym)
  LEFT JOIN activity AS a
         ON a.cohort_ym = cs.cohort_ym
        AND a.months_since = mo.months_since;
  INSERT INTO mart_refresh_log (refreshed_at, mart_name, row_count)
  VALUES (v_run_ts, 'mart_cohort_retention', ROW_COUNT());

  -- -------------------------------------------------------------------------
  -- 4. mart_seller_monthly: dense seller x month grid from each seller's first sale month
  --    to the end of the window (is_active = 0 rows make gaps / churn visible).
  -- -------------------------------------------------------------------------
  TRUNCATE TABLE mart_seller_monthly;
  INSERT INTO mart_seller_monthly (seller_id, `year_month`, gmv, orders, is_active)
  WITH RECURSIVE month_spine (month_start) AS (
    SELECT CAST(DATE_FORMAT(v_ws, '%Y-%m-01') AS DATE)
    UNION ALL
    SELECT month_start + INTERVAL 1 MONTH
    FROM month_spine
    WHERE month_start + INTERVAL 1 MONTH <= v_we
  ),
  seller_month_sales AS (
    SELECT seller_id,
           DATE_FORMAT(purchase_date, '%Y-%m') AS ym,
           SUM(item_gmv)                       AS gmv,
           COUNT(DISTINCT order_id)            AS orders
    FROM v_fact_order_items
    GROUP BY seller_id, DATE_FORMAT(purchase_date, '%Y-%m')
  ),
  seller_first AS (
    SELECT seller_id, MIN(ym) AS first_ym
    FROM seller_month_sales
    GROUP BY seller_id
  )
  SELECT sf.seller_id,
         DATE_FORMAT(ms.month_start, '%Y-%m')                AS ym,
         COALESCE(sms.gmv, 0)                                AS gmv,
         COALESCE(sms.orders, 0)                             AS orders,
         CASE WHEN sms.seller_id IS NULL THEN 0 ELSE 1 END   AS is_active
  FROM seller_first AS sf
  INNER JOIN month_spine AS ms
          ON DATE_FORMAT(ms.month_start, '%Y-%m') >= sf.first_ym
  LEFT JOIN seller_month_sales AS sms
         ON sms.seller_id = sf.seller_id
        AND sms.ym = DATE_FORMAT(ms.month_start, '%Y-%m');
  INSERT INTO mart_refresh_log (refreshed_at, mart_name, row_count)
  VALUES (v_run_ts, 'mart_seller_monthly', ROW_COUNT());

  -- -------------------------------------------------------------------------
  -- 5. mart_pareto_sellers: cumulative GMV share by seller rank (Pareto curve)
  -- -------------------------------------------------------------------------
  TRUNCATE TABLE mart_pareto_sellers;
  INSERT INTO mart_pareto_sellers (seller_id, gmv, gmv_rank, cum_gmv_share, seller_pct_rank)
  WITH seller_gmv AS (
    SELECT seller_id, SUM(item_gmv) AS gmv
    FROM v_fact_order_items
    GROUP BY seller_id
  )
  SELECT seller_id,
         gmv,
         ROW_NUMBER() OVER (ORDER BY gmv DESC, seller_id)                       AS gmv_rank,
         ROUND(SUM(gmv) OVER (ORDER BY gmv DESC, seller_id
                              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
               / SUM(gmv) OVER (), 6)                                           AS cum_gmv_share,
         ROUND(PERCENT_RANK() OVER (ORDER BY gmv DESC, seller_id), 6)           AS seller_pct_rank
  FROM seller_gmv;
  INSERT INTO mart_refresh_log (refreshed_at, mart_name, row_count)
  VALUES (v_run_ts, 'mart_pareto_sellers', ROW_COUNT());
END$$

-- ===========================================================================
-- sp_seller_scorecard(p_seller_id): GMV, orders, on-time %, avg review and the seller's
-- GMV rank among sellers whose main category (largest GMV) is the same.
-- Usage: CALL sp_seller_scorecard('4a3ca9315b744ce9f8e9374361493884');
-- ===========================================================================
CREATE PROCEDURE sp_seller_scorecard(IN p_seller_id CHAR(32))
READS SQL DATA
COMMENT 'One-row scorecard for a seller: GMV, orders, on-time %, avg review, rank in category'
BEGIN
  WITH seller_category_gmv AS (         -- GMV of every seller in every category
    SELECT f.seller_id, p.category_en, SUM(f.item_gmv) AS gmv
    FROM v_fact_order_items AS f
    INNER JOIN products AS p ON p.product_id = f.product_id
    GROUP BY f.seller_id, p.category_en
  ),
  seller_main_category AS (             -- main category = the one with the most GMV
    SELECT seller_id, category_en,
           ROW_NUMBER() OVER (PARTITION BY seller_id ORDER BY gmv DESC, category_en) AS rn
    FROM seller_category_gmv
  ),
  seller_totals AS (                    -- total GMV per seller, tagged with its main category
    SELECT scg.seller_id, smc.category_en AS main_category, SUM(scg.gmv) AS total_gmv
    FROM seller_category_gmv AS scg
    INNER JOIN seller_main_category AS smc
            ON smc.seller_id = scg.seller_id
           AND smc.rn = 1
    GROUP BY scg.seller_id, smc.category_en
  ),
  category_ranks AS (                   -- rank vs. sellers sharing the same main category
    SELECT seller_id, main_category, total_gmv,
           RANK()   OVER (PARTITION BY main_category ORDER BY total_gmv DESC) AS rank_in_category,
           COUNT(*) OVER (PARTITION BY main_category)                         AS sellers_in_category
    FROM seller_totals
  ),
  seller_orders AS (                    -- this seller's orders, one row per order
    SELECT order_id,
           MAX(is_valid_delivery) AS is_valid_delivery,
           MAX(is_late)           AS is_late,
           MAX(review_score)      AS review_score
    FROM v_fact_order_items
    WHERE seller_id = p_seller_id
    GROUP BY order_id
  ),
  seller_order_stats AS (
    SELECT COUNT(*)                                                             AS orders,
           ROUND(100 * (1 - SUM(is_late) / NULLIF(SUM(is_valid_delivery), 0)), 1) AS on_time_pct,
           ROUND(AVG(review_score), 2)                                          AS avg_review
    FROM seller_orders
  )
  SELECT cr.seller_id,
         cr.main_category,
         cr.total_gmv            AS gmv,
         sos.orders,
         sos.on_time_pct,
         sos.avg_review,
         cr.rank_in_category,
         cr.sellers_in_category
  FROM category_ranks AS cr
  CROSS JOIN seller_order_stats AS sos
  WHERE cr.seller_id = p_seller_id;
END$$

DELIMITER ;

SELECT routine_name, routine_type, routine_comment
FROM information_schema.routines
WHERE routine_schema = DATABASE()
ORDER BY routine_type, routine_name;
