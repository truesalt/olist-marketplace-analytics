/* ============================================================================
   File        : 07_data_quality_audit.sql
   Purpose     : One audit report (single result set) proving the core layer is complete
                 and consistent: row counts vs staging, primary-key uniqueness, orphan
                 foreign keys, timestamp anomalies, item-vs-payment reconciliation.
   Business Q  : "Can we trust the numbers?" - every later finding depends on this.
   SQL concepts: UNION ALL report, CTEs with column lists, scalar subqueries,
                 COUNT vs COUNT(DISTINCT), anti-join (LEFT JOIN ... IS NULL), EXISTS,
                 conditional aggregation, CASE status rules, ROUND/NULLIF
   Output      : check_name, table_name, metric_value, expected, status (PASS/WARN/FAIL)
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/setup/07_data_quality_audit.sql
                 `make quality` runs it via python/run_analysis.py --quality, saves the CSV and
                 fails the build if any row is FAIL.
   ========================================================================== */

USE olist;

-- @query: data_quality_report
WITH
-- 1. Core row counts vs staging, after the documented exclusions (R03, R08, R09, R16)
row_counts (table_name, core_rows, expected_rows) AS (
  SELECT 'category_translation',
         (SELECT COUNT(*) FROM category_translation),
         (SELECT COUNT(*) FROM stg_category_translation)
  UNION ALL
  SELECT 'geolocation_zip',                      -- distinct zips that keep >= 1 in-box point (R03)
         (SELECT COUNT(*) FROM geolocation_zip),
         (SELECT COUNT(DISTINCT LPAD(TRIM(geolocation_zip_code_prefix), 5, '0'))
          FROM stg_geolocation
          WHERE CAST(geolocation_lat AS DECIMAL(20,14)) BETWEEN -34 AND 6
            AND CAST(geolocation_lng AS DECIMAL(20,14)) BETWEEN -74 AND -34)
  UNION ALL
  SELECT 'customers', (SELECT COUNT(*) FROM customers), (SELECT COUNT(*) FROM stg_customers)
  UNION ALL
  SELECT 'sellers',   (SELECT COUNT(*) FROM sellers),   (SELECT COUNT(*) FROM stg_sellers)
  UNION ALL
  SELECT 'products',  (SELECT COUNT(*) FROM products),  (SELECT COUNT(*) FROM stg_products)
  UNION ALL
  SELECT 'orders',    (SELECT COUNT(*) FROM orders),    (SELECT COUNT(*) FROM stg_orders)
  UNION ALL
  SELECT 'order_items',                          -- minus non-positive prices (R16)
         (SELECT COUNT(*) FROM order_items),
         (SELECT COUNT(*) FROM stg_order_items WHERE CAST(price AS DECIMAL(10,2)) > 0)
  UNION ALL
  SELECT 'order_payments',                       -- minus payment_type = not_defined (R09)
         (SELECT COUNT(*) FROM order_payments),
         (SELECT COUNT(*) FROM stg_order_payments WHERE payment_type <> 'not_defined')
  UNION ALL
  SELECT 'order_reviews',                        -- one review per order after dedup (R08)
         (SELECT COUNT(*) FROM order_reviews),
         (SELECT COUNT(DISTINCT order_id) FROM stg_order_reviews)
  UNION ALL
  SELECT 'seller_leads', (SELECT COUNT(*) FROM seller_leads), (SELECT COUNT(*) FROM stg_mql)
),
-- 2. Primary-key uniqueness: rows vs distinct key values
pk_checks (table_name, n_rows, n_keys) AS (
  SELECT 'category_translation', COUNT(*), COUNT(DISTINCT category_pt) FROM category_translation
  UNION ALL SELECT 'geolocation_zip', COUNT(*), COUNT(DISTINCT zip_prefix) FROM geolocation_zip
  UNION ALL SELECT 'customers',       COUNT(*), COUNT(DISTINCT customer_id) FROM customers
  UNION ALL SELECT 'sellers',         COUNT(*), COUNT(DISTINCT seller_id) FROM sellers
  UNION ALL SELECT 'products',        COUNT(*), COUNT(DISTINCT product_id) FROM products
  UNION ALL SELECT 'orders',          COUNT(*), COUNT(DISTINCT order_id) FROM orders
  UNION ALL SELECT 'order_items',     COUNT(*), COUNT(DISTINCT order_id, order_item_id) FROM order_items
  UNION ALL SELECT 'order_payments',  COUNT(*), COUNT(DISTINCT order_id, payment_sequential)
            FROM order_payments
  UNION ALL SELECT 'order_reviews',   COUNT(*), COUNT(DISTINCT order_id) FROM order_reviews
  UNION ALL SELECT 'seller_leads',    COUNT(*), COUNT(DISTINCT mql_id) FROM seller_leads
),
-- 3. Orphan foreign keys via anti-joins (LEFT JOIN parent, keep rows where parent IS NULL)
orphan_checks (check_name, table_name, n_orphans) AS (
  SELECT 'orphan_fk_item_without_order', 'order_items', COUNT(*)
  FROM order_items AS oi LEFT JOIN orders AS o ON o.order_id = oi.order_id
  WHERE o.order_id IS NULL
  UNION ALL
  SELECT 'orphan_fk_item_without_product', 'order_items', COUNT(*)
  FROM order_items AS oi LEFT JOIN products AS p ON p.product_id = oi.product_id
  WHERE p.product_id IS NULL
  UNION ALL
  SELECT 'orphan_fk_item_without_seller', 'order_items', COUNT(*)
  FROM order_items AS oi LEFT JOIN sellers AS s ON s.seller_id = oi.seller_id
  WHERE s.seller_id IS NULL
  UNION ALL
  SELECT 'orphan_fk_payment_without_order', 'order_payments', COUNT(*)
  FROM order_payments AS op LEFT JOIN orders AS o ON o.order_id = op.order_id
  WHERE o.order_id IS NULL
  UNION ALL
  SELECT 'orphan_fk_review_without_order', 'order_reviews', COUNT(*)
  FROM order_reviews AS r LEFT JOIN orders AS o ON o.order_id = r.order_id
  WHERE o.order_id IS NULL
  UNION ALL
  SELECT 'orphan_fk_order_without_customer', 'orders', COUNT(*)
  FROM orders AS o LEFT JOIN customers AS c ON c.customer_id = o.customer_id
  WHERE c.customer_id IS NULL
),
-- 4. Items vs payments for non-canceled orders that have both (each side summed per side
--    separately, so the join cannot fan out)
reconciliation AS (
  SELECT itm.items_total, pay.payments_total,
         ROUND(100 * ABS(pay.payments_total - itm.items_total) / NULLIF(itm.items_total, 0), 3) AS gap_pct
  FROM (
    SELECT SUM(oi.price + oi.freight_value) AS items_total
    FROM order_items AS oi
    INNER JOIN orders AS o ON o.order_id = oi.order_id
    WHERE o.order_status <> 'canceled'
      AND EXISTS (SELECT 1 FROM order_payments AS op WHERE op.order_id = o.order_id)
  ) AS itm
  CROSS JOIN (
    SELECT SUM(op.payment_value) AS payments_total
    FROM order_payments AS op
    INNER JOIN orders AS o ON o.order_id = op.order_id
    WHERE o.order_status <> 'canceled'
      AND EXISTS (SELECT 1 FROM order_items AS oi WHERE oi.order_id = o.order_id)
  ) AS pay
)
SELECT 'row_count_vs_staging'       AS check_name,
       table_name,
       core_rows                    AS metric_value,
       CONCAT('= ', expected_rows)  AS expected,
       CASE WHEN core_rows = expected_rows THEN 'PASS' ELSE 'FAIL' END AS status
FROM row_counts
UNION ALL
SELECT 'pk_duplicate_keys', table_name, n_rows - n_keys, '= 0',
       CASE WHEN n_rows = n_keys THEN 'PASS' ELSE 'FAIL' END
FROM pk_checks
UNION ALL
SELECT check_name, table_name, n_orphans, '= 0',
       CASE WHEN n_orphans = 0 THEN 'PASS' ELSE 'FAIL' END
FROM orphan_checks
UNION ALL
SELECT 'pct_orders_with_ts_anomaly', 'orders', ROUND(100 * AVG(ts_anomaly), 3), '<= 1%',
       CASE WHEN AVG(ts_anomaly) > 0.01 THEN 'WARN' ELSE 'PASS' END
FROM orders
UNION ALL
SELECT 'pct_delivered_without_date', 'orders',
       ROUND(100 * AVG(CASE WHEN delivered_ts IS NULL THEN 1 ELSE 0 END), 3), '<= 1%',
       CASE WHEN AVG(CASE WHEN delivered_ts IS NULL THEN 1 ELSE 0 END) > 0.01 THEN 'WARN' ELSE 'PASS' END
FROM orders
WHERE order_status = 'delivered'
UNION ALL
SELECT 'valid_deliveries_with_negative_days', 'orders', COUNT(*), '= 0',  -- R11/R13 guard
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM orders
WHERE is_valid_delivery = 1
  AND (delivery_days < 0 OR estimated_date IS NULL)
UNION ALL
SELECT 'pct_customer_zips_missing_geolocation', 'customers',
       ROUND(100 * AVG(CASE WHEN g.zip_prefix IS NULL THEN 1 ELSE 0 END), 3), '<= 1%',
       CASE WHEN AVG(CASE WHEN g.zip_prefix IS NULL THEN 1 ELSE 0 END) > 0.01 THEN 'WARN' ELSE 'PASS' END
FROM customers AS c
LEFT JOIN geolocation_zip AS g ON g.zip_prefix = c.zip_prefix
UNION ALL
SELECT 'payments_vs_items_gap_pct', 'order_items/order_payments', gap_pct, '<= 2%',
       CASE WHEN gap_pct > 2 THEN 'WARN' ELSE 'PASS' END
FROM reconciliation
UNION ALL
-- Invisible control characters (e.g. a stray '\r' from Windows line endings) in key text fields
SELECT 'text_values_with_control_chars', 'products/translation/reviews/leads',
       (SELECT COUNT(*) FROM products             WHERE category_en REGEXP '[[:cntrl:]]')
     + (SELECT COUNT(*) FROM category_translation WHERE category_en REGEXP '[[:cntrl:]]')
     + (SELECT COUNT(*) FROM seller_leads         WHERE origin REGEXP '[[:cntrl:]]')
     + (SELECT COUNT(*) FROM order_reviews        WHERE review_answer_ts IS NULL),
       '= 0',
       CASE WHEN (SELECT COUNT(*) FROM products             WHERE category_en REGEXP '[[:cntrl:]]')
               + (SELECT COUNT(*) FROM category_translation WHERE category_en REGEXP '[[:cntrl:]]')
               + (SELECT COUNT(*) FROM seller_leads         WHERE origin REGEXP '[[:cntrl:]]')
               + (SELECT COUNT(*) FROM order_reviews        WHERE review_answer_ts IS NULL) = 0
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'max_orders_per_customer_unique_id', 'customers', MAX(n_order_ids), 'info only', 'PASS'
FROM (
  SELECT customer_unique_id, COUNT(*) AS n_order_ids
  FROM customers
  GROUP BY customer_unique_id
) AS per_person
UNION ALL
SELECT 'order_status_values_outside_check_list', 'stg_orders', COUNT(DISTINCT order_status), '= 0',
       CASE WHEN COUNT(DISTINCT order_status) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM stg_orders
WHERE order_status NOT IN ('delivered','shipped','canceled','unavailable','invoiced',
                           'processing','created','approved');
