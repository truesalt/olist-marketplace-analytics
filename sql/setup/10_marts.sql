/* ============================================================================
   File        : 10_marts.sql
   Purpose     : Create the mart_* summary tables ("materialized views") and fill them by
                 calling sp_refresh_marts(); then verify the monthly mart reconciles exactly
                 to the fact view and demo the parameterised seller scorecard.
   Business Q  : setup (fast, pre-aggregated sources for Power BI and repeated questions)
   SQL concepts: CREATE TABLE (composite PK), CREATE TABLE IF NOT EXISTS (persistent log),
                 CALL procedure, user variables, scalar subquery, reconciliation check
   Output      : mart_monthly_kpis, mart_lane_sla, mart_cohort_retention,
                 mart_seller_monthly, mart_pareto_sellers, mart_refresh_log
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/setup/10_marts.sql
   ========================================================================== */

USE olist;

-- Rates (*_pct, *_share) are stored as fractions 0-1; Power BI formats them as %.
DROP TABLE IF EXISTS mart_monthly_kpis;
CREATE TABLE mart_monthly_kpis (
  `year_month`   CHAR(7)       NOT NULL,   -- '2018-03'
  gmv            DECIMAL(14,2) NOT NULL,
  orders         INT           NOT NULL,
  customers      INT           NOT NULL,
  aov            DECIMAL(10,2),
  on_time_pct    DECIMAL(7,4),
  low_review_pct DECIMAL(7,4),
  new_customers  INT           NOT NULL,
  gmv_mom_pct    DECIMAL(10,4),            -- NULL for the first month (no previous month)
  gmv_yoy_pct    DECIMAL(10,4),            -- NULL unless the same month a year earlier exists
  PRIMARY KEY (`year_month`)
) COMMENT = 'Monthly marketplace KPIs inside the analysis window';

DROP TABLE IF EXISTS mart_lane_sla;
CREATE TABLE mart_lane_sla (
  seller_region        VARCHAR(15)  NOT NULL,
  customer_region      VARCHAR(15)  NOT NULL,
  seller_state         CHAR(2)      NOT NULL,
  customer_state       CHAR(2)      NOT NULL,
  delivered_orders     INT          NOT NULL,   -- valid deliveries on this lane
  late_orders          INT          NOT NULL,
  late_pct             DECIMAL(7,4),
  avg_delivery_days    DECIMAL(6,2),
  median_delivery_days DECIMAL(6,1),
  PRIMARY KEY (seller_state, customer_state)
) COMMENT = 'Delivery SLA per seller-state -> customer-state lane';

DROP TABLE IF EXISTS mart_cohort_retention;
CREATE TABLE mart_cohort_retention (
  cohort_month     CHAR(7)      NOT NULL,     -- month of first valid order
  months_since     INT          NOT NULL,     -- 0 = the cohort month itself
  active_customers INT          NOT NULL,
  cohort_size      INT          NOT NULL,
  retention_pct    DECIMAL(7,4) NOT NULL,
  PRIMARY KEY (cohort_month, months_since)
) COMMENT = 'Monthly cohort retention in long format';

DROP TABLE IF EXISTS mart_seller_monthly;
CREATE TABLE mart_seller_monthly (
  seller_id    CHAR(32)      NOT NULL,
  `year_month` CHAR(7)       NOT NULL,
  gmv          DECIMAL(12,2) NOT NULL,
  orders       INT           NOT NULL,
  is_active    BOOLEAN       NOT NULL,       -- >= 1 item sold that month
  PRIMARY KEY (seller_id, `year_month`)
) COMMENT = 'Seller x month activity grid from first sale to window end';

DROP TABLE IF EXISTS mart_pareto_sellers;
CREATE TABLE mart_pareto_sellers (
  seller_id       CHAR(32)      NOT NULL,
  gmv             DECIMAL(12,2) NOT NULL,
  gmv_rank        INT           NOT NULL,    -- 1 = largest seller
  cum_gmv_share   DECIMAL(9,6)  NOT NULL,    -- share of GMV from sellers ranked 1..gmv_rank
  seller_pct_rank DECIMAL(9,6)  NOT NULL,    -- PERCENT_RANK: 0 = top seller, 1 = smallest
  PRIMARY KEY (seller_id)
) COMMENT = 'Seller GMV concentration (Pareto curve)';

-- The refresh log is NOT dropped: it keeps the history of every refresh.
CREATE TABLE IF NOT EXISTS mart_refresh_log (
  log_id       INT AUTO_INCREMENT PRIMARY KEY,
  refreshed_at DATETIME    NOT NULL,
  mart_name    VARCHAR(40) NOT NULL,
  row_count    INT         NOT NULL
) COMMENT = 'One row per mart per sp_refresh_marts() run';

-- Fill all marts (the MySQL equivalent of REFRESH MATERIALIZED VIEW).
CALL sp_refresh_marts();

-- Latest refresh: rows written per mart.
SELECT mart_name, row_count, refreshed_at
FROM mart_refresh_log
WHERE refreshed_at = (SELECT MAX(refreshed_at) FROM mart_refresh_log)
ORDER BY log_id;

-- Gate check: the monthly mart must reconcile to the fact view to the cent.
SELECT
  (SELECT SUM(gmv)      FROM mart_monthly_kpis)  AS mart_gmv,
  (SELECT SUM(item_gmv) FROM v_fact_order_items) AS fact_gmv,
  CASE WHEN (SELECT SUM(gmv) FROM mart_monthly_kpis) = (SELECT SUM(item_gmv) FROM v_fact_order_items)
       THEN 'PASS' ELSE 'FAIL' END               AS exact_match;

-- Demo of the parameterised procedure: scorecard of the #1 seller by GMV.
SET @top_seller = (SELECT seller_id FROM mart_pareto_sellers WHERE gmv_rank = 1);
CALL sp_seller_scorecard(@top_seller);
