/* ============================================================================
   File        : 01_staging_schema.sql
   Purpose     : Create one raw "landing" table per CSV file. Every column is text
                 and there are no keys, so the bulk load can never fail on a dirty
                 value - cleaning and typing happen later (06) where they are logged.
   Business Q  : setup
   SQL concepts: DROP TABLE IF EXISTS, CREATE TABLE, VARCHAR vs TEXT, table COMMENT
   Output      : 11 tables stg_* (columns named exactly like the CSV headers)
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/setup/01_staging_schema.sql
   ========================================================================== */

USE olist;

-- ---------------------------------------------------------------------------
-- Brazilian E-Commerce Public Dataset by Olist (9 files)
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS stg_orders;
CREATE TABLE stg_orders (
  order_id                      VARCHAR(255),
  customer_id                   VARCHAR(255),
  order_status                  VARCHAR(255),
  order_purchase_timestamp      VARCHAR(255),
  order_approved_at             VARCHAR(255),
  order_delivered_carrier_date  VARCHAR(255),
  order_delivered_customer_date VARCHAR(255),
  order_estimated_delivery_date VARCHAR(255)
) COMMENT = 'Raw olist_orders_dataset.csv';

DROP TABLE IF EXISTS stg_order_items;
CREATE TABLE stg_order_items (
  order_id            VARCHAR(255),
  order_item_id       VARCHAR(255),
  product_id          VARCHAR(255),
  seller_id           VARCHAR(255),
  shipping_limit_date VARCHAR(255),
  price               VARCHAR(255),
  freight_value       VARCHAR(255)
) COMMENT = 'Raw olist_order_items_dataset.csv';

DROP TABLE IF EXISTS stg_order_payments;
CREATE TABLE stg_order_payments (
  order_id             VARCHAR(255),
  payment_sequential   VARCHAR(255),
  payment_type         VARCHAR(255),
  payment_installments VARCHAR(255),
  payment_value        VARCHAR(255)
) COMMENT = 'Raw olist_order_payments_dataset.csv';

DROP TABLE IF EXISTS stg_order_reviews;
CREATE TABLE stg_order_reviews (
  review_id               VARCHAR(255),
  order_id                VARCHAR(255),
  review_score            VARCHAR(255),
  review_comment_title    TEXT,          -- free text: may be long / contain newlines
  review_comment_message  TEXT,
  review_creation_date    VARCHAR(255),
  review_answer_timestamp VARCHAR(255)
) COMMENT = 'Raw olist_order_reviews_dataset.csv';

DROP TABLE IF EXISTS stg_customers;
CREATE TABLE stg_customers (
  customer_id              VARCHAR(255),
  customer_unique_id       VARCHAR(255),
  customer_zip_code_prefix VARCHAR(255),
  customer_city            VARCHAR(255),
  customer_state           VARCHAR(255)
) COMMENT = 'Raw olist_customers_dataset.csv';

DROP TABLE IF EXISTS stg_sellers;
CREATE TABLE stg_sellers (
  seller_id              VARCHAR(255),
  seller_zip_code_prefix VARCHAR(255),
  seller_city            VARCHAR(255),
  seller_state           VARCHAR(255)
) COMMENT = 'Raw olist_sellers_dataset.csv';

DROP TABLE IF EXISTS stg_products;
CREATE TABLE stg_products (
  product_id                 VARCHAR(255),
  product_category_name      VARCHAR(255),
  product_name_lenght        VARCHAR(255),  -- (sic) misspelled in the source; renamed in core (R05)
  product_description_lenght VARCHAR(255),  -- (sic)
  product_photos_qty         VARCHAR(255),
  product_weight_g           VARCHAR(255),
  product_length_cm          VARCHAR(255),
  product_height_cm          VARCHAR(255),
  product_width_cm           VARCHAR(255)
) COMMENT = 'Raw olist_products_dataset.csv';

DROP TABLE IF EXISTS stg_geolocation;
CREATE TABLE stg_geolocation (
  geolocation_zip_code_prefix VARCHAR(255),
  geolocation_lat             VARCHAR(255),
  geolocation_lng             VARCHAR(255),
  geolocation_city            VARCHAR(255),
  geolocation_state           VARCHAR(255)
) COMMENT = 'Raw olist_geolocation_dataset.csv (~1M points, many per zip prefix)';

DROP TABLE IF EXISTS stg_category_translation;
CREATE TABLE stg_category_translation (
  product_category_name         VARCHAR(255),
  product_category_name_english VARCHAR(255)
) COMMENT = 'Raw product_category_name_translation.csv';

-- ---------------------------------------------------------------------------
-- Marketing Funnel by Olist (2 files)
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS stg_mql;
CREATE TABLE stg_mql (
  mql_id             VARCHAR(255),
  first_contact_date VARCHAR(255),
  landing_page_id    VARCHAR(255),
  origin             VARCHAR(255)
) COMMENT = 'Raw olist_marketing_qualified_leads_dataset.csv (seller leads)';

DROP TABLE IF EXISTS stg_closed_deals;
CREATE TABLE stg_closed_deals (
  mql_id                        VARCHAR(255),
  seller_id                     VARCHAR(255),
  sdr_id                        VARCHAR(255),
  sr_id                         VARCHAR(255),
  won_date                      VARCHAR(255),
  business_segment              VARCHAR(255),
  lead_type                     VARCHAR(255),
  lead_behaviour_profile        VARCHAR(255),
  has_company                   VARCHAR(255),
  has_gtin                      VARCHAR(255),
  average_stock                 VARCHAR(255),
  business_type                 VARCHAR(255),
  declared_product_catalog_size VARCHAR(255),
  declared_monthly_revenue      VARCHAR(255)
) COMMENT = 'Raw olist_closed_deals_dataset.csv (won seller leads)';

SELECT table_name, table_comment
FROM information_schema.tables
WHERE table_schema = DATABASE()
  AND table_name LIKE 'stg\_%'
ORDER BY table_name;
