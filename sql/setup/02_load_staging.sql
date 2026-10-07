/* ============================================================================
   File        : 02_load_staging.sql
   Purpose     : Bulk-load the 11 raw CSVs into stg_* and check row counts against
                 the expected counts from PROJECT_SPEC §2.3 (WARN if off by > 1%).
   Business Q  : setup
   SQL concepts: TRUNCATE, LOAD DATA LOCAL INFILE (CSV options), CTE with column list,
                 UNION ALL, INNER JOIN ... USING, CASE, ABS, ROUND
   Output      : stg_* filled; result set (table_name, expected_rows, actual_rows,
                 diff_pct, status)
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/setup/02_load_staging.sql
                 Must run from the repo root: file paths are relative (`make load` does this).
   ========================================================================== */

USE olist;

/* CSV format notes (checked with `head -2`, `file` and `tr -cd '\r' < f | wc -c`):
   - 9 files end lines with '\n'. product_category_name_translation.csv and
     olist_order_reviews_dataset.csv end lines with '\r\n' (Windows) -> LINES TERMINATED BY '\r\n'.
     macOS `file` did NOT flag this; a first load with '\n' left an invisible '\r' at the end of
     every English category name (caught when pandas quoted those values in a CSV). Counting
     carriage returns per file is the reliable check.
   - Comma separators; only some fields are quoted -> OPTIONALLY ENCLOSED BY '"'.
   - Review messages contain newlines inside quotes; the enclosure handles them.
   - ESCAPED BY '' turns OFF MySQL's default backslash escaping. The data contains raw
     backslashes (e.g. a review ending in  :\"  and a seller city "rio de janeiro \rio de
     janeiro"). With the default escape, \" would swallow the closing quote and shift
     every following column, and \r would become a carriage return.
   - product_category_name_translation.csv starts with a UTF-8 BOM; it sits on the
     header line, so IGNORE 1 LINES discards it. */

-- ---------------------------------------------------------------------------
-- E-commerce dataset
-- ---------------------------------------------------------------------------
TRUNCATE TABLE stg_orders;
LOAD DATA LOCAL INFILE 'data/raw/olist_orders_dataset.csv'
INTO TABLE stg_orders
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(order_id, customer_id, order_status, order_purchase_timestamp, order_approved_at,
 order_delivered_carrier_date, order_delivered_customer_date, order_estimated_delivery_date);

TRUNCATE TABLE stg_order_items;
LOAD DATA LOCAL INFILE 'data/raw/olist_order_items_dataset.csv'
INTO TABLE stg_order_items
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(order_id, order_item_id, product_id, seller_id, shipping_limit_date, price, freight_value);

TRUNCATE TABLE stg_order_payments;
LOAD DATA LOCAL INFILE 'data/raw/olist_order_payments_dataset.csv'
INTO TABLE stg_order_payments
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(order_id, payment_sequential, payment_type, payment_installments, payment_value);

TRUNCATE TABLE stg_order_reviews;
LOAD DATA LOCAL INFILE 'data/raw/olist_order_reviews_dataset.csv'
INTO TABLE stg_order_reviews
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\r\n'   -- Windows line endings
IGNORE 1 LINES
(review_id, order_id, review_score, review_comment_title, review_comment_message,
 review_creation_date, review_answer_timestamp);

TRUNCATE TABLE stg_customers;
LOAD DATA LOCAL INFILE 'data/raw/olist_customers_dataset.csv'
INTO TABLE stg_customers
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state);

TRUNCATE TABLE stg_sellers;
LOAD DATA LOCAL INFILE 'data/raw/olist_sellers_dataset.csv'
INTO TABLE stg_sellers
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(seller_id, seller_zip_code_prefix, seller_city, seller_state);

TRUNCATE TABLE stg_products;
LOAD DATA LOCAL INFILE 'data/raw/olist_products_dataset.csv'
INTO TABLE stg_products
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(product_id, product_category_name, product_name_lenght, product_description_lenght,
 product_photos_qty, product_weight_g, product_length_cm, product_height_cm, product_width_cm);

TRUNCATE TABLE stg_geolocation;
LOAD DATA LOCAL INFILE 'data/raw/olist_geolocation_dataset.csv'
INTO TABLE stg_geolocation
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(geolocation_zip_code_prefix, geolocation_lat, geolocation_lng, geolocation_city,
 geolocation_state);

TRUNCATE TABLE stg_category_translation;
LOAD DATA LOCAL INFILE 'data/raw/product_category_name_translation.csv'
INTO TABLE stg_category_translation
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\r\n'   -- Windows line endings
IGNORE 1 LINES
(product_category_name, product_category_name_english);

-- ---------------------------------------------------------------------------
-- Marketing funnel dataset
-- ---------------------------------------------------------------------------
TRUNCATE TABLE stg_mql;
LOAD DATA LOCAL INFILE 'data/raw/olist_marketing_qualified_leads_dataset.csv'
INTO TABLE stg_mql
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(mql_id, first_contact_date, landing_page_id, origin);

TRUNCATE TABLE stg_closed_deals;
LOAD DATA LOCAL INFILE 'data/raw/olist_closed_deals_dataset.csv'
INTO TABLE stg_closed_deals
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(mql_id, seller_id, sdr_id, sr_id, won_date, business_segment, lead_type,
 lead_behaviour_profile, has_company, has_gtin, average_stock, business_type,
 declared_product_catalog_size, declared_monthly_revenue);

-- ---------------------------------------------------------------------------
-- Row-count check: actual vs expected (PROJECT_SPEC §2.3). WARN = off by more than 1%
-- -> investigate, then use `make load-fallback` (pandas loader) if LOAD DATA is at fault.
-- ---------------------------------------------------------------------------
WITH expected (table_name, expected_rows) AS (
  SELECT 'stg_orders',               99441 UNION ALL
  SELECT 'stg_order_items',         112650 UNION ALL
  SELECT 'stg_order_payments',      103886 UNION ALL
  SELECT 'stg_order_reviews',        99224 UNION ALL
  SELECT 'stg_customers',            99441 UNION ALL
  SELECT 'stg_sellers',               3095 UNION ALL
  SELECT 'stg_products',             32951 UNION ALL
  SELECT 'stg_geolocation',        1000163 UNION ALL
  SELECT 'stg_category_translation',    71 UNION ALL
  SELECT 'stg_mql',                   8000 UNION ALL
  SELECT 'stg_closed_deals',           842
),
actual (table_name, actual_rows) AS (
  SELECT 'stg_orders',               COUNT(*) FROM stg_orders               UNION ALL
  SELECT 'stg_order_items',          COUNT(*) FROM stg_order_items          UNION ALL
  SELECT 'stg_order_payments',       COUNT(*) FROM stg_order_payments       UNION ALL
  SELECT 'stg_order_reviews',        COUNT(*) FROM stg_order_reviews        UNION ALL
  SELECT 'stg_customers',            COUNT(*) FROM stg_customers            UNION ALL
  SELECT 'stg_sellers',              COUNT(*) FROM stg_sellers              UNION ALL
  SELECT 'stg_products',             COUNT(*) FROM stg_products             UNION ALL
  SELECT 'stg_geolocation',          COUNT(*) FROM stg_geolocation          UNION ALL
  SELECT 'stg_category_translation', COUNT(*) FROM stg_category_translation UNION ALL
  SELECT 'stg_mql',                  COUNT(*) FROM stg_mql                  UNION ALL
  SELECT 'stg_closed_deals',         COUNT(*) FROM stg_closed_deals
)
SELECT
  e.table_name,
  e.expected_rows,
  a.actual_rows,
  ROUND(100 * (a.actual_rows - e.expected_rows) / e.expected_rows, 2) AS diff_pct,
  CASE WHEN ABS(a.actual_rows - e.expected_rows) / e.expected_rows > 0.01
       THEN 'WARN' ELSE 'OK' END                                      AS status
FROM expected AS e
INNER JOIN actual AS a USING (table_name)
ORDER BY e.table_name;
