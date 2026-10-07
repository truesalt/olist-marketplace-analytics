/* ============================================================================
   File        : 06_transform_load_core.sql
   Purpose     : Clean, type and load staging -> core in ONE all-or-nothing transaction,
                 applying data-quality rules R01-R17 and logging what each rule touched.
   Business Q  : setup (makes every later number trustworthy and auditable)
   SQL concepts: stored procedure, START TRANSACTION / COMMIT, DECLARE EXIT HANDLER +
                 ROLLBACK + RESIGNAL, INSERT ... SELECT, INSERT ... WITH (CTE), UPDATE,
                 DELETE, ROW_COUNT(), NULLIF/TRIM/LPAD/STR_TO_DATE/CAST, COALESCE, CASE,
                 ROW_NUMBER() dedup (DISTINCT ON emulation), GROUP_CONCAT, LEFT JOIN,
                 conditional aggregation, COLLATE utf8mb4_bin for exact string comparison
   Output      : core tables filled; dq_log(rule_id, table_name, description,
                 rows_affected, logged_at) with one row per rule
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/setup/06_transform_load_core.sql
   ========================================================================== */

USE olist;

-- Audit trail of every cleaning rule (rebuilt on each run of this file).
DROP TABLE IF EXISTS dq_log;
CREATE TABLE dq_log (
  log_id        INT          AUTO_INCREMENT PRIMARY KEY,   -- preserves insertion order
  rule_id       VARCHAR(10)  NOT NULL,
  table_name    VARCHAR(40)  NOT NULL,
  description   VARCHAR(255) NOT NULL,
  rows_affected INT,
  logged_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
) COMMENT = 'Data-quality log: one row per cleaning rule applied by sp_load_core()';

DROP PROCEDURE IF EXISTS sp_load_core;

DELIMITER $$

CREATE PROCEDURE sp_load_core()
MODIFIES SQL DATA
COMMENT 'Staging -> core transform in one transaction; logs rules R01-R17 to dq_log'
BEGIN
  -- Any SQL error: undo everything since START TRANSACTION, then re-raise the original
  -- error so the caller (mysql client / make) sees it and stops.
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  -- -------------------------------------------------------------------------
  -- 0. Empty the core tables, children before parents (FK order).
  --    DELETE, not TRUNCATE: TRUNCATE is DDL and would implicitly COMMIT,
  --    which would break the all-or-nothing guarantee of this transaction.
  -- -------------------------------------------------------------------------
  DELETE FROM seller_leads;
  DELETE FROM order_reviews;
  DELETE FROM order_payments;
  DELETE FROM order_items;
  DELETE FROM orders;
  DELETE FROM products;
  DELETE FROM sellers;
  DELETE FROM customers;
  DELETE FROM geolocation_zip;
  DELETE FROM category_translation;
  DELETE FROM dq_log;

  -- -------------------------------------------------------------------------
  -- Rule counts measured on staging BEFORE transforming (rules applied inline below)
  -- -------------------------------------------------------------------------
  -- R01: zip prefixes shorter than 5 digits (leading zero lost) - padded with LPAD below.
  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  SELECT 'R01', 'customers/sellers/geo',
         'Zip prefixes shorter than 5 chars, left-padded with zeros (LPAD)',
         (SELECT COUNT(*) FROM stg_customers   WHERE CHAR_LENGTH(TRIM(customer_zip_code_prefix)) < 5)
       + (SELECT COUNT(*) FROM stg_sellers     WHERE CHAR_LENGTH(TRIM(seller_zip_code_prefix)) < 5)
       + (SELECT COUNT(*) FROM stg_geolocation WHERE CHAR_LENGTH(TRIM(geolocation_zip_code_prefix)) < 5);

  -- R02: empty strings in date/number columns -> NULL (NULLIF(TRIM(x), '') before casting).
  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  SELECT 'R02', 'orders', 'Empty timestamp strings converted to NULL (approved/carrier/delivered)',
         SUM(CASE WHEN TRIM(order_approved_at)             = '' THEN 1 ELSE 0 END)
       + SUM(CASE WHEN TRIM(order_delivered_carrier_date)  = '' THEN 1 ELSE 0 END)
       + SUM(CASE WHEN TRIM(order_delivered_customer_date) = '' THEN 1 ELSE 0 END)
  FROM stg_orders;

  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  SELECT 'R02', 'products', 'Products with empty numeric attributes (lengths/photos/weight/dims) -> NULL',
         COUNT(*)
  FROM stg_products
  WHERE TRIM(product_name_lenght) = '' OR TRIM(product_description_lenght) = ''
     OR TRIM(product_photos_qty)  = '' OR TRIM(product_weight_g) = ''
     OR TRIM(product_length_cm)   = '' OR TRIM(product_height_cm) = '' OR TRIM(product_width_cm) = '';

  -- -------------------------------------------------------------------------
  -- 1. category_translation
  -- -------------------------------------------------------------------------
  INSERT INTO category_translation (category_pt, category_en)
  SELECT TRIM(product_category_name), TRIM(product_category_name_english)
  FROM stg_category_translation;
  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  VALUES ('LOAD', 'category_translation', 'Rows loaded', ROW_COUNT());

  -- -------------------------------------------------------------------------
  -- 2. geolocation_zip (R01, R03, R04): ~1M raw points -> one centroid per zip prefix
  -- -------------------------------------------------------------------------
  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  SELECT 'R03', 'geolocation_zip', 'Raw geolocation points outside Brazil bounding box dropped',
         COUNT(*)
  FROM stg_geolocation
  WHERE NOT (CAST(geolocation_lat AS DECIMAL(20,14)) BETWEEN -34 AND 6
         AND CAST(geolocation_lng AS DECIMAL(20,14)) BETWEEN -74 AND -34);

  INSERT INTO geolocation_zip (zip_prefix, lat, lng, city, state, n_points)
  WITH valid_points AS (            -- R03: keep only points inside Brazil's bounding box
    SELECT LPAD(TRIM(geolocation_zip_code_prefix), 5, '0')   AS zip_prefix,   -- R01
           CAST(geolocation_lat AS DECIMAL(20,14))            AS lat,
           CAST(geolocation_lng AS DECIMAL(20,14))            AS lng,
           fn_strip_accents(geolocation_city)                 AS city_clean,   -- R04
           UPPER(TRIM(geolocation_state))                     AS state
    FROM stg_geolocation
    WHERE CAST(geolocation_lat AS DECIMAL(20,14)) BETWEEN -34 AND 6
      AND CAST(geolocation_lng AS DECIMAL(20,14)) BETWEEN -74 AND -34
  ),
  zip_centroid AS (                 -- one averaged coordinate per zip prefix
    SELECT zip_prefix, AVG(lat) AS lat, AVG(lng) AS lng, COUNT(*) AS n_points
    FROM valid_points
    GROUP BY zip_prefix
  ),
  city_votes AS (                   -- how many points name each city for a zip prefix
    SELECT zip_prefix, city_clean, state, COUNT(*) AS n_votes
    FROM valid_points
    GROUP BY zip_prefix, city_clean, state
  ),
  city_mode AS (                    -- most frequent city per zip (ties -> alphabetical)
    SELECT zip_prefix, city_clean, state,
           ROW_NUMBER() OVER (PARTITION BY zip_prefix ORDER BY n_votes DESC, city_clean) AS rn
    FROM city_votes
  )
  SELECT zc.zip_prefix, ROUND(zc.lat, 6), ROUND(zc.lng, 6), cm.city_clean, cm.state, zc.n_points
  FROM zip_centroid AS zc
  INNER JOIN city_mode AS cm
          ON cm.zip_prefix = zc.zip_prefix
         AND cm.rn = 1;
  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  VALUES ('R03', 'geolocation_zip',
          'Zip prefixes aggregated (AVG lat/lng, mode city, n_points)', ROW_COUNT());

  -- -------------------------------------------------------------------------
  -- 3. customers (R01, R04, R17)
  -- -------------------------------------------------------------------------
  INSERT INTO customers (customer_id, customer_unique_id, zip_prefix, city, city_clean, state, region)
  SELECT TRIM(customer_id),
         TRIM(customer_unique_id),
         LPAD(NULLIF(TRIM(customer_zip_code_prefix), ''), 5, '0'),   -- R01
         TRIM(customer_city),
         fn_strip_accents(customer_city),                              -- R04
         UPPER(TRIM(customer_state)),
         fn_region(UPPER(TRIM(customer_state)))                        -- R17
  FROM stg_customers;
  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  VALUES ('LOAD', 'customers', 'Rows loaded', ROW_COUNT());

  -- -------------------------------------------------------------------------
  -- 4. sellers (R01, R04, R17)
  -- -------------------------------------------------------------------------
  INSERT INTO sellers (seller_id, zip_prefix, city, city_clean, state, region)
  SELECT TRIM(seller_id),
         LPAD(NULLIF(TRIM(seller_zip_code_prefix), ''), 5, '0'),
         TRIM(seller_city),
         fn_strip_accents(seller_city),
         UPPER(TRIM(seller_state)),
         fn_region(UPPER(TRIM(seller_state)))
  FROM stg_sellers;
  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  VALUES ('LOAD', 'sellers', 'Rows loaded', ROW_COUNT());

  -- R04: rows whose city text changed after cleaning. COLLATE utf8mb4_bin compares exact
  -- bytes; the default accent-insensitive collation would call 'São Paulo' = 'sao paulo'.
  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  SELECT 'R04', 'customers', 'City names changed by fn_strip_accents (case/accents/spaces)', COUNT(*)
  FROM customers
  WHERE city_clean COLLATE utf8mb4_bin <> city COLLATE utf8mb4_bin;

  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  SELECT 'R04', 'sellers', 'City names changed by fn_strip_accents (case/accents/spaces)', COUNT(*)
  FROM sellers
  WHERE city_clean COLLATE utf8mb4_bin <> city COLLATE utf8mb4_bin;

  -- R17: region derived from state; 'Unknown' would signal an unexpected state code.
  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  SELECT 'R17', 'customers+sellers', 'Rows with region = Unknown after fn_region (expected 0)',
         (SELECT COUNT(*) FROM customers WHERE region = 'Unknown')
       + (SELECT COUNT(*) FROM sellers   WHERE region = 'Unknown');

  -- -------------------------------------------------------------------------
  -- 5. products (R02, R05, R06, R07)
  -- -------------------------------------------------------------------------
  INSERT INTO products (product_id, category_pt, category_en, name_length, description_length,
                        photos_qty, weight_g, length_cm, height_cm, width_cm)
  SELECT TRIM(sp.product_id),
         COALESCE(NULLIF(TRIM(sp.product_category_name), ''), 'sem_categoria'),      -- R06
         CASE
           WHEN NULLIF(TRIM(sp.product_category_name), '') IS NULL THEN 'unknown'    -- R06
           ELSE COALESCE(ct.category_en, TRIM(sp.product_category_name))           -- R07
         END,
         CAST(NULLIF(TRIM(sp.product_name_lenght), '') AS UNSIGNED),                -- R05 rename
         CAST(NULLIF(TRIM(sp.product_description_lenght), '') AS UNSIGNED),         -- R05 rename
         CAST(NULLIF(TRIM(sp.product_photos_qty), '') AS UNSIGNED),
         CAST(NULLIF(TRIM(sp.product_weight_g), '') AS UNSIGNED),
         CAST(NULLIF(TRIM(sp.product_length_cm), '') AS UNSIGNED),
         CAST(NULLIF(TRIM(sp.product_height_cm), '') AS UNSIGNED),
         CAST(NULLIF(TRIM(sp.product_width_cm), '') AS UNSIGNED)
  FROM stg_products AS sp
  LEFT JOIN category_translation AS ct
         ON ct.category_pt = TRIM(sp.product_category_name);
  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  VALUES ('R05', 'products',
          'Renamed product_name_lenght/description_lenght -> name_length/description_length',
          ROW_COUNT());

  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  SELECT 'R06', 'products', 'Missing category -> category_pt sem_categoria / category_en unknown', COUNT(*)
  FROM products
  WHERE category_pt = 'sem_categoria';

  -- R07: categories with no English translation keep their Portuguese name; list them.
  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  SELECT 'R07', 'products',
         CONCAT('No translation, kept Portuguese name: ',
                COALESCE(GROUP_CONCAT(DISTINCT p.category_pt ORDER BY p.category_pt SEPARATOR ', '),
                         '(none)')),
         COUNT(*)
  FROM products AS p
  LEFT JOIN category_translation AS ct
         ON ct.category_pt = p.category_pt
  WHERE ct.category_pt IS NULL
    AND p.category_pt <> 'sem_categoria';

  -- -------------------------------------------------------------------------
  -- 6. orders (R02, R11, R12, R13)
  -- -------------------------------------------------------------------------
  INSERT INTO orders (order_id, customer_id, order_status, purchase_ts, approved_ts,
                      carrier_ts, delivered_ts, estimated_date)
  SELECT TRIM(order_id),
         TRIM(customer_id),
         TRIM(order_status),
         STR_TO_DATE(NULLIF(TRIM(order_purchase_timestamp), ''),      '%Y-%m-%d %H:%i:%s'),
         STR_TO_DATE(NULLIF(TRIM(order_approved_at), ''),             '%Y-%m-%d %H:%i:%s'),  -- R02
         STR_TO_DATE(NULLIF(TRIM(order_delivered_carrier_date), ''),  '%Y-%m-%d %H:%i:%s'),
         STR_TO_DATE(NULLIF(TRIM(order_delivered_customer_date), ''), '%Y-%m-%d %H:%i:%s'),
         DATE(STR_TO_DATE(NULLIF(TRIM(order_estimated_delivery_date), ''), '%Y-%m-%d %H:%i:%s'))
  FROM stg_orders;
  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  VALUES ('LOAD', 'orders', 'Rows loaded', ROW_COUNT());

  -- R11: timestamps out of logical order. Row kept, flagged, and excluded from SLA metrics.
  -- (A comparison with a NULL timestamp is NULL, i.e. not flagged.)
  UPDATE orders
  SET ts_anomaly = 1
  WHERE approved_ts  < purchase_ts
     OR carrier_ts   < approved_ts
     OR delivered_ts < carrier_ts
     OR delivered_ts < purchase_ts;
  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  VALUES ('R11', 'orders',
          'Timestamp anomalies -> ts_anomaly=1 (approved<purchase, carrier<approved, delivered<carrier)',
          ROW_COUNT());

  -- R12: 'delivered' status but no delivery date -> cannot measure SLA; stays is_valid_delivery = 0.
  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  SELECT 'R12', 'orders', 'Status delivered but delivered_ts NULL (is_valid_delivery = 0)', COUNT(*)
  FROM orders
  WHERE order_status = 'delivered'
    AND delivered_ts IS NULL;

  -- R13: derive SLA fields only for clean, completed deliveries.
  UPDATE orders
  SET is_valid_delivery = 1,
      delivery_days     = DATEDIFF(DATE(delivered_ts), DATE(purchase_ts)),
      delay_days        = DATEDIFF(DATE(delivered_ts), estimated_date),
      is_late           = (DATEDIFF(DATE(delivered_ts), estimated_date) > 0)  -- boolean -> 1/0
  WHERE order_status = 'delivered'
    AND delivered_ts IS NOT NULL
    AND ts_anomaly = 0;
  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  VALUES ('R13', 'orders', 'Valid deliveries: delivery_days, delay_days, is_late derived', ROW_COUNT());

  -- -------------------------------------------------------------------------
  -- 7. order_items (R16)
  -- -------------------------------------------------------------------------
  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  SELECT 'R16', 'order_items', 'Items with non-positive price excluded', COUNT(*)
  FROM stg_order_items
  WHERE CAST(price AS DECIMAL(10,2)) <= 0;

  INSERT INTO order_items (order_id, order_item_id, product_id, seller_id, shipping_limit_ts,
                           price, freight_value)
  SELECT TRIM(order_id),
         CAST(order_item_id AS UNSIGNED),
         TRIM(product_id),
         TRIM(seller_id),
         STR_TO_DATE(NULLIF(TRIM(shipping_limit_date), ''), '%Y-%m-%d %H:%i:%s'),
         CAST(price AS DECIMAL(10,2)),
         CAST(freight_value AS DECIMAL(10,2))
  FROM stg_order_items
  WHERE CAST(price AS DECIMAL(10,2)) > 0;                                       -- R16
  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  VALUES ('LOAD', 'order_items', 'Rows loaded', ROW_COUNT());

  -- -------------------------------------------------------------------------
  -- 8. order_payments (R09, R10)
  -- -------------------------------------------------------------------------
  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  SELECT 'R10', 'order_payments', 'payment_installments = 0 set to 1', COUNT(*)
  FROM stg_order_payments
  WHERE CAST(payment_installments AS UNSIGNED) = 0;

  INSERT INTO order_payments (order_id, payment_sequential, payment_type, payment_installments,
                              payment_value)
  SELECT TRIM(order_id),
         CAST(payment_sequential AS UNSIGNED),
         TRIM(payment_type),
         CASE WHEN CAST(payment_installments AS UNSIGNED) = 0 THEN 1             -- R10
              ELSE CAST(payment_installments AS UNSIGNED) END,
         CAST(payment_value AS DECIMAL(10,2))
  FROM stg_order_payments;

  -- R09: 'not_defined' payment type carries no usable information -> remove (DELETE demo).
  DELETE FROM order_payments
  WHERE payment_type = 'not_defined';
  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  VALUES ('R09', 'order_payments', 'Payments with payment_type = not_defined deleted', ROW_COUNT());

  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  SELECT 'LOAD', 'order_payments', 'Rows loaded', COUNT(*)
  FROM order_payments;

  -- -------------------------------------------------------------------------
  -- 9. order_reviews (R08): keep ONE review per order = the latest answered one.
  --    ROW_NUMBER() ... = 1 is MySQL's replacement for Postgres DISTINCT ON.
  -- -------------------------------------------------------------------------
  INSERT INTO order_reviews (review_id, order_id, review_score, has_comment,
                             review_created_date, review_answer_ts)
  WITH typed AS (
    SELECT TRIM(review_id)                                                        AS review_id,
           TRIM(order_id)                                                         AS order_id,
           CAST(review_score AS UNSIGNED)                                         AS review_score,
           CASE WHEN TRIM(review_comment_title) <> ''
                  OR TRIM(review_comment_message) <> '' THEN 1 ELSE 0 END         AS has_comment,
           DATE(STR_TO_DATE(NULLIF(TRIM(review_creation_date), ''), '%Y-%m-%d %H:%i:%s'))
             AS review_created_date,
           STR_TO_DATE(NULLIF(TRIM(review_answer_timestamp), ''), '%Y-%m-%d %H:%i:%s')    AS review_answer_ts
    FROM stg_order_reviews
  ),
  ranked AS (
    SELECT typed.*,
           ROW_NUMBER() OVER (
             PARTITION BY order_id
             ORDER BY review_answer_ts DESC, review_created_date DESC,
                      review_id DESC                  -- final tie-breaker -> deterministic
           ) AS rn
    FROM typed
  )
  SELECT review_id, order_id, review_score, has_comment, review_created_date, review_answer_ts
  FROM ranked
  WHERE rn = 1;
  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  VALUES ('LOAD', 'order_reviews', 'Rows loaded (one per order)', ROW_COUNT());

  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  SELECT 'R08', 'order_reviews', 'Duplicate review rows removed (orders with >1 review, latest kept)',
         (SELECT COUNT(*) FROM stg_order_reviews) - (SELECT COUNT(*) FROM order_reviews);

  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  SELECT 'R08', 'order_reviews', 'review_id values reused across more than one order (info)', COUNT(*)
  FROM (
    SELECT review_id
    FROM stg_order_reviews
    GROUP BY review_id
    HAVING COUNT(DISTINCT order_id) > 1
  ) AS reused_ids;

  -- -------------------------------------------------------------------------
  -- 10. seller_leads (R14, R15): every MQL, LEFT JOINed to its closed deal (if any)
  -- -------------------------------------------------------------------------
  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  SELECT 'R14', 'seller_leads', 'Blank lead origin set to unknown', COUNT(*)
  FROM stg_mql
  WHERE TRIM(origin) = '';

  INSERT INTO seller_leads (mql_id, first_contact_date, landing_page_id, origin, is_won, seller_id,
                            won_date, business_segment, lead_type, business_type, days_to_close)
  SELECT TRIM(m.mql_id),
         STR_TO_DATE(TRIM(m.first_contact_date), '%Y-%m-%d'),
         NULLIF(TRIM(m.landing_page_id), ''),
         COALESCE(NULLIF(TRIM(m.origin), ''), 'unknown'),                          -- R14
         CASE WHEN d.mql_id IS NOT NULL THEN 1 ELSE 0 END,                          -- R15 is_won
         NULLIF(TRIM(d.seller_id), ''),
         DATE(STR_TO_DATE(NULLIF(TRIM(d.won_date), ''), '%Y-%m-%d %H:%i:%s')),
         NULLIF(TRIM(d.business_segment), ''),
         NULLIF(TRIM(d.lead_type), ''),
         NULLIF(TRIM(d.business_type), ''),
         DATEDIFF(DATE(STR_TO_DATE(NULLIF(TRIM(d.won_date), ''), '%Y-%m-%d %H:%i:%s')),   -- R15
                  STR_TO_DATE(TRIM(m.first_contact_date), '%Y-%m-%d'))
  FROM stg_mql AS m
  LEFT JOIN stg_closed_deals AS d
         ON TRIM(d.mql_id) = TRIM(m.mql_id);
  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  VALUES ('LOAD', 'seller_leads', 'Rows loaded (all MQLs)', ROW_COUNT());

  INSERT INTO dq_log (rule_id, table_name, description, rows_affected)
  SELECT 'R15', 'seller_leads',
          'Leads won (closed deal found); days_to_close = won_date - first_contact_date',
         SUM(is_won)
  FROM seller_leads;

  COMMIT;
END$$

DELIMITER ;

-- Run the whole transform (atomic: on any error nothing is half-loaded).
CALL sp_load_core();

-- What each rule did (also exported to docs/data_quality_log.md).
SELECT rule_id, table_name, description, rows_affected
FROM dq_log
ORDER BY log_id;
