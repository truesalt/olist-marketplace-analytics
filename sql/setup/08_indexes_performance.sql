/* ============================================================================
   File        : 08_indexes_performance.sql
   Purpose     : Measure query plans BEFORE and AFTER adding secondary indexes, and show
                 why a predicate must be SARGable (Search-ARGument-able) to use an index.
   Business Q  : setup / engineering - "will dashboards stay fast as data grows?"
   SQL concepts: CREATE INDEX / DROP INDEX (idempotent via information_schema + dynamic SQL:
                 PREPARE / EXECUTE / DEALLOCATE), composite index, ANALYZE TABLE,
                 EXPLAIN, EXPLAIN ANALYZE, SARGability, handler counters
                 (performance_schema.session_status) as "rows examined"
   Output      : printed plans (`make perf` saves them to results/perf/08_explain_analyze.txt);
                 indexes idx_* created; summary in docs/performance.md
   Run with    : mysql --local-infile=1 --raw -u $MYSQL_USER -p olist < sql/setup/08_indexes_performance.sql
   ========================================================================== */

USE olist;

-- ---------------------------------------------------------------------------
-- Helpers: MySQL has no "DROP INDEX IF EXISTS" / "CREATE INDEX IF NOT EXISTS", so check
-- information_schema.statistics and run the DDL as dynamic SQL. Makes this file re-runnable.
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_drop_index_if_exists;
DROP PROCEDURE IF EXISTS sp_create_index_if_missing;

DELIMITER $$

CREATE PROCEDURE sp_drop_index_if_exists(IN p_table VARCHAR(64), IN p_index VARCHAR(64))
MODIFIES SQL DATA
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.statistics
             WHERE table_schema = DATABASE() AND table_name = p_table AND index_name = p_index) THEN
    SET @ddl = CONCAT('DROP INDEX `', p_index, '` ON `', p_table, '`');
    PREPARE stmt FROM @ddl;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
  END IF;
END$$

CREATE PROCEDURE sp_create_index_if_missing(IN p_table VARCHAR(64), IN p_index VARCHAR(64),
                                            IN p_columns VARCHAR(255))
MODIFIES SQL DATA
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.statistics
                 WHERE table_schema = DATABASE() AND table_name = p_table AND index_name = p_index) THEN
    SET @ddl = CONCAT('CREATE INDEX `', p_index, '` ON `', p_table, '` (', p_columns, ')');
    PREPARE stmt FROM @ddl;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
  END IF;
END$$

DELIMITER ;

-- ---------------------------------------------------------------------------
-- Parameters + benchmark targets (read from config / data, never hard-coded)
-- ---------------------------------------------------------------------------
SET @ws       = CAST(fn_cfg('window_start') AS DATE);
SET @we_excl  = CAST(fn_cfg('window_end') AS DATE) + INTERVAL 1 DAY;   -- exclusive upper bound
SET @min_lane = CAST(fn_cfg('min_orders_lane') AS UNSIGNED);
-- the person with the most order ids, and one funnel-acquired seller, for point lookups
SET @heavy_customer = (SELECT customer_unique_id FROM customers
                       GROUP BY customer_unique_id ORDER BY COUNT(*) DESC, customer_unique_id LIMIT 1);
SET @won_seller     = (SELECT MIN(seller_id) FROM seller_leads WHERE is_won = 1);

-- ===========================================================================
-- STEP 1 - BASELINE: primary keys + the indexes InnoDB must keep for FOREIGN KEYs
-- (orders.customer_id, order_items.seller_id, order_items.product_id exist implicitly
--  because every FK column needs an index). Remove the other secondary indexes.
-- ===========================================================================
CALL sp_drop_index_if_exists('orders',         'idx_orders_purchase_ts');
CALL sp_drop_index_if_exists('orders',         'idx_orders_status_purchase');
CALL sp_drop_index_if_exists('customers',      'idx_customers_unique_id');
CALL sp_drop_index_if_exists('order_payments', 'idx_payments_type');
CALL sp_drop_index_if_exists('seller_leads',   'idx_leads_seller');
ANALYZE TABLE orders, order_items, customers, sellers, order_payments, seller_leads;

SELECT 'BASELINE INDEXES' AS phase, table_name, index_name,
       GROUP_CONCAT(column_name ORDER BY seq_in_index) AS index_columns
FROM information_schema.statistics
WHERE table_schema = DATABASE()
  AND table_name IN ('orders','order_items','customers','order_payments','seller_leads')
GROUP BY table_name, index_name
ORDER BY table_name, index_name;

-- Warm the buffer pool so BEFORE and AFTER both read from memory (fair comparison).
SELECT COUNT(*) AS warm_orders FROM orders;
SELECT COUNT(*) AS warm_items FROM order_items;
SELECT COUNT(*) AS warm_customers FROM customers;
SELECT COUNT(*) AS warm_payments FROM order_payments;

-- "Rows examined" = growth of the Handler_read_* counters (rows the storage engine handed to
-- the SQL layer). Reading the counter itself costs a few reads; measure that overhead once.
SELECT SUM(VARIABLE_VALUE) INTO @h0 FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';
SELECT SUM(VARIABLE_VALUE) INTO @h1 FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';
SET @h_overhead = @h1 - @h0;

-- ---------------------------------------------------------------------------
-- Q1 (a04 lane SLA core): valid deliveries per seller-state -> customer-state lane
-- ---------------------------------------------------------------------------
SELECT '>>> Q1 a04_lane_sla - BEFORE' AS benchmark;
SELECT SUM(VARIABLE_VALUE) INTO @h0 FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';
EXPLAIN ANALYZE
WITH order_lanes AS (
  SELECT DISTINCT o.order_id, s.state AS seller_state, c.state AS customer_state, o.is_late
  FROM orders AS o
  INNER JOIN customers   AS c  ON c.customer_id = o.customer_id
  INNER JOIN order_items AS oi ON oi.order_id   = o.order_id
  INNER JOIN sellers     AS s  ON s.seller_id   = oi.seller_id
  WHERE o.order_status = 'delivered'
    AND o.is_valid_delivery = 1
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
)
SELECT seller_state, customer_state, COUNT(*) AS delivered_orders, SUM(is_late) AS late_orders
FROM order_lanes
GROUP BY seller_state, customer_state
HAVING COUNT(*) >= @min_lane;
SELECT 'Q1 a04_lane_sla' AS benchmark, 'BEFORE' AS phase,
       SUM(VARIABLE_VALUE) - @h0 - @h_overhead AS rows_examined
FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';

-- ---------------------------------------------------------------------------
-- Q2 (a11 cohorts core): active customers by first-order cohort and month offset
-- ---------------------------------------------------------------------------
SELECT '>>> Q2 a11_cohorts - BEFORE' AS benchmark;
SELECT SUM(VARIABLE_VALUE) INTO @h0 FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';
EXPLAIN ANALYZE
WITH customer_months AS (
  SELECT DISTINCT c.customer_unique_id, DATE_FORMAT(o.purchase_ts, '%Y%m') AS ym
  FROM orders AS o
  INNER JOIN customers AS c ON c.customer_id = o.customer_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
),
cohorts AS (
  SELECT customer_unique_id, MIN(ym) AS cohort_ym
  FROM customer_months
  GROUP BY customer_unique_id
)
SELECT co.cohort_ym, PERIOD_DIFF(cm.ym, co.cohort_ym) AS months_since, COUNT(*) AS active_customers
FROM customer_months AS cm
INNER JOIN cohorts AS co ON co.customer_unique_id = cm.customer_unique_id
GROUP BY co.cohort_ym, PERIOD_DIFF(cm.ym, co.cohort_ym);
SELECT 'Q2 a11_cohorts' AS benchmark, 'BEFORE' AS phase,
       SUM(VARIABLE_VALUE) - @h0 - @h_overhead AS rows_examined
FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';

-- ---------------------------------------------------------------------------
-- Q3-Q6: selective look-ups (where secondary indexes are supposed to shine)
-- ---------------------------------------------------------------------------
SELECT '>>> Q3 one customer history - BEFORE' AS benchmark;
SELECT SUM(VARIABLE_VALUE) INTO @h0 FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';
EXPLAIN ANALYZE
SELECT o.order_id, o.purchase_ts, o.order_status
FROM customers AS c
INNER JOIN orders AS o ON o.customer_id = c.customer_id
WHERE c.customer_unique_id = @heavy_customer;
SELECT 'Q3 one_customer_history' AS benchmark, 'BEFORE' AS phase,
       SUM(VARIABLE_VALUE) - @h0 - @h_overhead AS rows_examined
FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';

SELECT '>>> Q4 one week of orders - BEFORE' AS benchmark;
SELECT SUM(VARIABLE_VALUE) INTO @h0 FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';
EXPLAIN ANALYZE
SELECT COUNT(*) AS orders_in_week
FROM orders
WHERE purchase_ts >= '2018-03-05' AND purchase_ts < '2018-03-12';
SELECT 'Q4 one_week_orders' AS benchmark, 'BEFORE' AS phase,
       SUM(VARIABLE_VALUE) - @h0 - @h_overhead AS rows_examined
FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';

SELECT '>>> Q5 voucher payments - BEFORE' AS benchmark;
SELECT SUM(VARIABLE_VALUE) INTO @h0 FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';
EXPLAIN ANALYZE
SELECT COUNT(*) AS voucher_payments
FROM order_payments
WHERE payment_type = 'voucher';
SELECT 'Q5 voucher_payments' AS benchmark, 'BEFORE' AS phase,
       SUM(VARIABLE_VALUE) - @h0 - @h_overhead AS rows_examined
FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';

SELECT '>>> Q6 lead of one seller - BEFORE' AS benchmark;
SELECT SUM(VARIABLE_VALUE) INTO @h0 FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';
EXPLAIN ANALYZE
SELECT mql_id, origin, won_date
FROM seller_leads
WHERE seller_id = @won_seller;
SELECT 'Q6 seller_lead_lookup' AS benchmark, 'BEFORE' AS phase,
       SUM(VARIABLE_VALUE) - @h0 - @h_overhead AS rows_examined
FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';

-- ===========================================================================
-- STEP 2 - CREATE the secondary indexes from PROJECT_SPEC §6.8.
-- For the three FK columns InnoDB already had an implicit index; creating an explicitly named
-- one lets InnoDB silently drop the implicit duplicate (same performance, clearer name).
-- ===========================================================================
CALL sp_create_index_if_missing('orders',         'idx_orders_customer_id',     'customer_id');
CALL sp_create_index_if_missing('orders',         'idx_orders_purchase_ts',     'purchase_ts');
CALL sp_create_index_if_missing('orders',         'idx_orders_status_purchase', 'order_status, purchase_ts');
CALL sp_create_index_if_missing('order_items',    'idx_items_seller_id',        'seller_id');
CALL sp_create_index_if_missing('order_items',    'idx_items_product_id',       'product_id');
CALL sp_create_index_if_missing('customers',      'idx_customers_unique_id',    'customer_unique_id');
CALL sp_create_index_if_missing('order_payments', 'idx_payments_type',          'payment_type');
CALL sp_create_index_if_missing('seller_leads',   'idx_leads_seller',           'seller_id');
ANALYZE TABLE orders, order_items, customers, sellers, order_payments, seller_leads;

SELECT 'INDEXES AFTER' AS phase, table_name, index_name,
       GROUP_CONCAT(column_name ORDER BY seq_in_index) AS index_columns
FROM information_schema.statistics
WHERE table_schema = DATABASE()
  AND table_name IN ('orders','order_items','customers','order_payments','seller_leads')
GROUP BY table_name, index_name
ORDER BY table_name, index_name;

-- ===========================================================================
-- STEP 3 - AFTER: identical queries
-- ===========================================================================
SELECT '>>> Q1 a04_lane_sla - AFTER' AS benchmark;
SELECT SUM(VARIABLE_VALUE) INTO @h0 FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';
EXPLAIN ANALYZE
WITH order_lanes AS (
  SELECT DISTINCT o.order_id, s.state AS seller_state, c.state AS customer_state, o.is_late
  FROM orders AS o
  INNER JOIN customers   AS c  ON c.customer_id = o.customer_id
  INNER JOIN order_items AS oi ON oi.order_id   = o.order_id
  INNER JOIN sellers     AS s  ON s.seller_id   = oi.seller_id
  WHERE o.order_status = 'delivered'
    AND o.is_valid_delivery = 1
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
)
SELECT seller_state, customer_state, COUNT(*) AS delivered_orders, SUM(is_late) AS late_orders
FROM order_lanes
GROUP BY seller_state, customer_state
HAVING COUNT(*) >= @min_lane;
SELECT 'Q1 a04_lane_sla' AS benchmark, 'AFTER' AS phase,
       SUM(VARIABLE_VALUE) - @h0 - @h_overhead AS rows_examined
FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';

SELECT '>>> Q2 a11_cohorts - AFTER' AS benchmark;
SELECT SUM(VARIABLE_VALUE) INTO @h0 FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';
EXPLAIN ANALYZE
WITH customer_months AS (
  SELECT DISTINCT c.customer_unique_id, DATE_FORMAT(o.purchase_ts, '%Y%m') AS ym
  FROM orders AS o
  INNER JOIN customers AS c ON c.customer_id = o.customer_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
),
cohorts AS (
  SELECT customer_unique_id, MIN(ym) AS cohort_ym
  FROM customer_months
  GROUP BY customer_unique_id
)
SELECT co.cohort_ym, PERIOD_DIFF(cm.ym, co.cohort_ym) AS months_since, COUNT(*) AS active_customers
FROM customer_months AS cm
INNER JOIN cohorts AS co ON co.customer_unique_id = cm.customer_unique_id
GROUP BY co.cohort_ym, PERIOD_DIFF(cm.ym, co.cohort_ym);
SELECT 'Q2 a11_cohorts' AS benchmark, 'AFTER' AS phase,
       SUM(VARIABLE_VALUE) - @h0 - @h_overhead AS rows_examined
FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';

SELECT '>>> Q3 one customer history - AFTER' AS benchmark;
SELECT SUM(VARIABLE_VALUE) INTO @h0 FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';
EXPLAIN ANALYZE
SELECT o.order_id, o.purchase_ts, o.order_status
FROM customers AS c
INNER JOIN orders AS o ON o.customer_id = c.customer_id
WHERE c.customer_unique_id = @heavy_customer;
SELECT 'Q3 one_customer_history' AS benchmark, 'AFTER' AS phase,
       SUM(VARIABLE_VALUE) - @h0 - @h_overhead AS rows_examined
FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';

SELECT '>>> Q4 one week of orders - AFTER' AS benchmark;
SELECT SUM(VARIABLE_VALUE) INTO @h0 FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';
EXPLAIN ANALYZE
SELECT COUNT(*) AS orders_in_week
FROM orders
WHERE purchase_ts >= '2018-03-05' AND purchase_ts < '2018-03-12';
SELECT 'Q4 one_week_orders' AS benchmark, 'AFTER' AS phase,
       SUM(VARIABLE_VALUE) - @h0 - @h_overhead AS rows_examined
FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';

SELECT '>>> Q5 voucher payments - AFTER' AS benchmark;
SELECT SUM(VARIABLE_VALUE) INTO @h0 FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';
EXPLAIN ANALYZE
SELECT COUNT(*) AS voucher_payments
FROM order_payments
WHERE payment_type = 'voucher';
SELECT 'Q5 voucher_payments' AS benchmark, 'AFTER' AS phase,
       SUM(VARIABLE_VALUE) - @h0 - @h_overhead AS rows_examined
FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';

SELECT '>>> Q6 lead of one seller - AFTER' AS benchmark;
SELECT SUM(VARIABLE_VALUE) INTO @h0 FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';
EXPLAIN ANALYZE
SELECT mql_id, origin, won_date
FROM seller_leads
WHERE seller_id = @won_seller;
SELECT 'Q6 seller_lead_lookup' AS benchmark, 'AFTER' AS phase,
       SUM(VARIABLE_VALUE) - @h0 - @h_overhead AS rows_examined
FROM performance_schema.session_status WHERE VARIABLE_NAME LIKE 'Handler_read%';

-- ===========================================================================
-- STEP 4 - SARGability demo (index on orders.purchase_ts now exists)
--  (a) YEAR(purchase_ts) = 2018 wraps the column in a function: the B-tree is ordered by
--      purchase_ts, not by YEAR(purchase_ts), so MySQL cannot seek - it must evaluate YEAR()
--      for every entry (type = index / ALL: full scan).
--  (b) purchase_ts >= '2018-01-01' AND purchase_ts < '2019-01-01' compares the bare column
--      with constants: MySQL seeks to the first 2018 entry and stops at the last one
--      (type = range). Same rows returned, far fewer rows touched.
-- ===========================================================================
SELECT '>>> SARGability (a) non-SARGable: WHERE YEAR(purchase_ts) = 2018' AS benchmark;
EXPLAIN
SELECT COUNT(*) FROM orders WHERE YEAR(purchase_ts) = 2018;
EXPLAIN ANALYZE
SELECT COUNT(*) FROM orders WHERE YEAR(purchase_ts) = 2018;

SELECT '>>> SARGability (b) SARGable: WHERE purchase_ts >= 2018-01-01 AND < 2019-01-01' AS benchmark;
EXPLAIN
SELECT COUNT(*) FROM orders WHERE purchase_ts >= '2018-01-01' AND purchase_ts < '2019-01-01';
EXPLAIN ANALYZE
SELECT COUNT(*) FROM orders WHERE purchase_ts >= '2018-01-01' AND purchase_ts < '2019-01-01';

-- Same lesson, more selective: one month (March 2018) written both ways.
SELECT '>>> SARGability (c) one month: DATE_FORMAT(...) = 2018-03 vs range' AS benchmark;
EXPLAIN ANALYZE
SELECT COUNT(*) FROM orders WHERE DATE_FORMAT(purchase_ts, '%Y-%m') = '2018-03';
EXPLAIN ANALYZE
SELECT COUNT(*) FROM orders WHERE purchase_ts >= '2018-03-01' AND purchase_ts < '2018-04-01';
