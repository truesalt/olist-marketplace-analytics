/* ============================================================================
   File        : 03_core_schema.sql
   Purpose     : Create the typed, constrained "core" tables that all analysis reads.
                 Staging is text-only; here every column gets a real type plus PK, FK,
                 NOT NULL and CHECK rules, so bad data fails loudly instead of silently.
   Business Q  : setup
   SQL concepts: CREATE TABLE, data types (CHAR/VARCHAR/DECIMAL/DATE/DATETIME/TINYINT(1)),
                 BOOLEAN (= TINYINT(1)), PRIMARY KEY (single + composite), FOREIGN KEY,
                 NOT NULL, DEFAULT, CHECK,
                 secondary INDEX, table COMMENT, FK-safe DROP order
   Output      : category_translation, geolocation_zip, customers, sellers, products,
                 orders, order_items, order_payments, order_reviews, seller_leads (empty;
                 filled by sp_load_core() in 06)
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/setup/03_core_schema.sql
   ========================================================================== */

USE olist;

-- Flags are declared BOOLEAN, which MySQL stores as TINYINT(1) (there is no true boolean type).
-- Writing TINYINT(1) literally triggers MySQL 8's "integer display width is deprecated" warning.

-- Drop children before parents so no FOREIGN KEY blocks the DROP (reverse of create order).
DROP TABLE IF EXISTS seller_leads;
DROP TABLE IF EXISTS order_reviews;
DROP TABLE IF EXISTS order_payments;
DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS sellers;
DROP TABLE IF EXISTS customers;
DROP TABLE IF EXISTS geolocation_zip;
DROP TABLE IF EXISTS category_translation;

-- ---------------------------------------------------------------------------
-- Lookup tables
-- ---------------------------------------------------------------------------
CREATE TABLE category_translation (
  category_pt VARCHAR(80) NOT NULL,
  category_en VARCHAR(80) NOT NULL,
  PRIMARY KEY (category_pt)
) COMMENT = 'Portuguese -> English product category names (71 rows)';

CREATE TABLE geolocation_zip (
  zip_prefix CHAR(5)      NOT NULL,
  lat        DECIMAL(9,6) NOT NULL,   -- centroid = AVG of the valid points for this prefix
  lng        DECIMAL(9,6) NOT NULL,
  city       VARCHAR(80),             -- most frequent (accent-stripped) city name for the prefix
  state      CHAR(2),
  n_points   INT          NOT NULL,   -- how many raw points were averaged
  PRIMARY KEY (zip_prefix),
  -- Brazil's bounding box: anything outside is a geocoding error (rule R03)
  CONSTRAINT chk_geo_lat CHECK (lat BETWEEN -34 AND 6),
  CONSTRAINT chk_geo_lng CHECK (lng BETWEEN -74 AND -34)
) COMMENT = 'One row per 5-digit zip prefix: centroid of ~1M raw geolocation points';

-- ---------------------------------------------------------------------------
-- Parties: customers and sellers
-- ---------------------------------------------------------------------------
CREATE TABLE customers (
  customer_id        CHAR(32)    NOT NULL,  -- one per ORDER (grain trap: not the person)
  customer_unique_id CHAR(32)    NOT NULL,  -- the actual person; use for repeat/cohort/RFM
  zip_prefix         CHAR(5),
  city               VARCHAR(80),           -- raw city text
  city_clean         VARCHAR(80),           -- fn_strip_accents(city) (rule R04)
  state              CHAR(2)     NOT NULL,
  region             VARCHAR(15),           -- fn_region(state) (rule R17)
  PRIMARY KEY (customer_id),
  INDEX idx_customers_unique_id (customer_unique_id)
) COMMENT = 'Order-level customer records; customer_unique_id identifies the person';

CREATE TABLE sellers (
  seller_id  CHAR(32)    NOT NULL,
  zip_prefix CHAR(5),
  city       VARCHAR(80),
  city_clean VARCHAR(80),
  state      CHAR(2)     NOT NULL,
  region     VARCHAR(15),
  PRIMARY KEY (seller_id)
) COMMENT = 'Marketplace sellers (3,095)';

-- ---------------------------------------------------------------------------
-- Products
-- ---------------------------------------------------------------------------
CREATE TABLE products (
  product_id         CHAR(32)    NOT NULL,
  category_pt        VARCHAR(80),           -- 'sem_categoria' when missing (rule R06)
  category_en        VARCHAR(80) NOT NULL,  -- translation, else the Portuguese name (R07)
  name_length        INT,                   -- renamed from product_name_lenght (R05)
  description_length INT,                   -- renamed from product_description_lenght (R05)
  photos_qty         INT,
  weight_g           INT,
  length_cm          INT,
  height_cm          INT,
  width_cm           INT,
  PRIMARY KEY (product_id),
  CONSTRAINT chk_products_weight CHECK (weight_g >= 0)
) COMMENT = 'Product catalogue with English category names';

-- ---------------------------------------------------------------------------
-- Orders and their children
-- ---------------------------------------------------------------------------
CREATE TABLE orders (
  order_id          CHAR(32)    NOT NULL,
  customer_id       CHAR(32)    NOT NULL,
  order_status      VARCHAR(20) NOT NULL,
  purchase_ts       DATETIME    NOT NULL,
  approved_ts       DATETIME,
  carrier_ts        DATETIME,              -- handed to the carrier
  delivered_ts      DATETIME,              -- delivered to the customer
  estimated_date    DATE,                  -- delivery date promised at purchase
  delivery_days     INT,                   -- delivered date - purchase date (valid deliveries only)
  delay_days        INT,                   -- delivered date - estimated date; > 0 means late
  is_late           BOOLEAN,               -- 1 if delay_days > 0 (NULL if not a valid delivery)
  ts_anomaly        BOOLEAN     NOT NULL DEFAULT 0,  -- timestamps out of order (rule R11)
  is_valid_delivery BOOLEAN     NOT NULL DEFAULT 0,  -- delivered + has date + no anomaly (R13)
  PRIMARY KEY (order_id),
  CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id) REFERENCES customers (customer_id),
  CONSTRAINT chk_orders_status CHECK (order_status IN
    ('delivered','shipped','canceled','unavailable','invoiced','processing','created','approved'))
) COMMENT = 'One row per order with derived delivery/SLA fields';

CREATE TABLE order_items (
  order_id          CHAR(32)      NOT NULL,
  order_item_id     INT           NOT NULL,  -- 1..n within the order
  product_id        CHAR(32)      NOT NULL,
  seller_id         CHAR(32)      NOT NULL,
  shipping_limit_ts DATETIME,
  price             DECIMAL(10,2) NOT NULL,
  freight_value     DECIMAL(10,2) NOT NULL,
  PRIMARY KEY (order_id, order_item_id),
  CONSTRAINT fk_items_order   FOREIGN KEY (order_id)   REFERENCES orders (order_id),
  CONSTRAINT fk_items_product FOREIGN KEY (product_id) REFERENCES products (product_id),
  CONSTRAINT fk_items_seller  FOREIGN KEY (seller_id)  REFERENCES sellers (seller_id),
  CONSTRAINT chk_items_price   CHECK (price > 0),
  CONSTRAINT chk_items_freight CHECK (freight_value >= 0)
) COMMENT = 'Order lines: one row per item (the GMV grain)';

CREATE TABLE order_payments (
  order_id             CHAR(32)      NOT NULL,
  payment_sequential   INT           NOT NULL,  -- 1..n payment methods used on the order
  payment_type         VARCHAR(20)   NOT NULL,
  payment_installments INT           NOT NULL,
  payment_value        DECIMAL(10,2) NOT NULL,
  PRIMARY KEY (order_id, payment_sequential),
  CONSTRAINT fk_payments_order FOREIGN KEY (order_id) REFERENCES orders (order_id),
  CONSTRAINT chk_payments_value        CHECK (payment_value >= 0),
  CONSTRAINT chk_payments_installments CHECK (payment_installments >= 1)
) COMMENT = 'Payments per order (several rows when vouchers/cards are combined)';

CREATE TABLE order_reviews (
  review_id           CHAR(32)   NOT NULL,  -- NOT unique: the source reuses some review_ids
  order_id            CHAR(32)   NOT NULL,
  review_score        TINYINT    NOT NULL,
  has_comment         BOOLEAN,              -- 1 if title or message was non-empty
  review_created_date DATE,
  review_answer_ts    DATETIME,
  PRIMARY KEY (order_id),                   -- one review per order after dedup (rule R08)
  CONSTRAINT fk_reviews_order FOREIGN KEY (order_id) REFERENCES orders (order_id),
  CONSTRAINT chk_reviews_score CHECK (review_score BETWEEN 1 AND 5)
) COMMENT = 'Latest review per order (review text dropped; only has_comment kept)';

-- ---------------------------------------------------------------------------
-- Seller acquisition funnel (marketing dataset)
-- ---------------------------------------------------------------------------
CREATE TABLE seller_leads (
  mql_id             CHAR(32)    NOT NULL,
  first_contact_date DATE        NOT NULL,
  landing_page_id    CHAR(32),
  origin             VARCHAR(30) NOT NULL,  -- acquisition channel; 'unknown' if blank (R14)
  is_won             BOOLEAN     NOT NULL,  -- 1 if a closed deal exists (R15)
  -- seller_id is deliberately NOT a FOREIGN KEY: many won sellers never made a sale in
  -- the orders data (or signed after it ends), so they are absent from `sellers`.
  -- Enforcing the FK would force us to drop exactly the leads the funnel must count.
  seller_id          CHAR(32),
  won_date           DATE,
  business_segment   VARCHAR(60),
  lead_type          VARCHAR(30),
  business_type      VARCHAR(30),
  days_to_close      INT,                   -- won_date - first_contact_date (R15)
  PRIMARY KEY (mql_id)
) COMMENT = 'Marketing-qualified seller leads joined to closed deals';

SELECT table_name, table_rows, table_comment
FROM information_schema.tables
WHERE table_schema = DATABASE()
  AND table_type = 'BASE TABLE'
  AND table_name IN ('category_translation','geolocation_zip','customers','sellers','products',
                     'orders','order_items','order_payments','order_reviews','seller_leads')
ORDER BY create_time, table_name;
