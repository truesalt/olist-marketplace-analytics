# Data dictionary

Generated from MySQL `information_schema` (types are exact) with one example value per column. Grain and keys are stated per object. Marts are documented in `sql/setup/10_marts.sql`; staging tables mirror the CSV headers 1:1 (all text).

## Core tables (sql/setup/03_core_schema.sql, filled by 06)

### `category_translation` (table)
Portuguese -> English product category names (71 rows)

| Column | Type | Key / null | Meaning | Example |
|---|---|---|---|---|
| `category_pt` | varchar(80) | PK NOT NULL | Product category name in Portuguese ('sem_categoria' = missing) | agro_industria_e_comercio |
| `category_en` | varchar(80) | NOT NULL | Product category in English (Portuguese kept when no translation exists) | agro_industry_and_commerce |

### `geolocation_zip` (table)
One row per 5-digit zip prefix: centroid of ~1M raw geolocation points

| Column | Type | Key / null | Meaning | Example |
|---|---|---|---|---|
| `zip_prefix` | char(5) | PK NOT NULL | First 5 digits of the Brazilian postcode (CEP), zero-padded | 01001 |
| `lat` | decimal(9,6) | NOT NULL | Latitude of the zip-prefix centroid (average of valid raw points) | -23.550190 |
| `lng` | decimal(9,6) | NOT NULL | Longitude of the zip-prefix centroid | -46.634024 |
| `city` | varchar(80) |  | Most frequent accent-stripped city name among the zip prefix's points | sao paulo |
| `state` | char(2) |  | Brazilian state code (UF), 2 letters | SP |
| `n_points` | int | NOT NULL | Number of raw geolocation points averaged into the centroid | 26 |

### `customers` (table)
Order-level customer records; customer_unique_id identifies the person

| Column | Type | Key / null | Meaning | Example |
|---|---|---|---|---|
| `customer_id` | char(32) | PK NOT NULL | Customer key PER ORDER (one per order - not the person) | 00012a2ce6f8dcda20d059ce98491703 |
| `customer_unique_id` | char(32) | index/FK NOT NULL | The actual person; use for repeat, cohorts, RFM | 248ffe10d632bebe4f7267f1f44844c9 |
| `zip_prefix` | char(5) |  | First 5 digits of the Brazilian postcode (CEP), zero-padded | 06273 |
| `city` | varchar(80) |  | City name as written in the source | osasco |
| `city_clean` | varchar(80) |  | City lower-cased, accents/apostrophes/hyphens removed (fn_strip_accents) | osasco |
| `state` | char(2) | NOT NULL | Brazilian state code (UF), 2 letters | SP |
| `region` | varchar(15) |  | Brazilian macro-region derived from state (fn_region) | Southeast |

### `sellers` (table)
Marketplace sellers (3,095)

| Column | Type | Key / null | Meaning | Example |
|---|---|---|---|---|
| `seller_id` | char(32) | PK NOT NULL | Seller key | 0015a82c2db000af6aaaf3ae2ecb0532 |
| `zip_prefix` | char(5) |  | First 5 digits of the Brazilian postcode (CEP), zero-padded | 09080 |
| `city` | varchar(80) |  | City name as written in the source | santo andre |
| `city_clean` | varchar(80) |  | City lower-cased, accents/apostrophes/hyphens removed (fn_strip_accents) | santo andre |
| `state` | char(2) | NOT NULL | Brazilian state code (UF), 2 letters | SP |
| `region` | varchar(15) |  | Brazilian macro-region derived from state (fn_region) | Southeast |

### `products` (table)
Product catalogue with English category names

| Column | Type | Key / null | Meaning | Example |
|---|---|---|---|---|
| `product_id` | char(32) | PK NOT NULL | Product key | 00066f42aeeb9f3007548bb9d3f33c38 |
| `category_pt` | varchar(80) |  | Product category name in Portuguese ('sem_categoria' = missing) | perfumaria |
| `category_en` | varchar(80) | NOT NULL | Product category in English (Portuguese kept when no translation exists) | perfumery |
| `name_length` | int |  | Characters in the product name (source column product_name_lenght) | 53 |
| `description_length` | int |  | Characters in the product description | 596 |
| `photos_qty` | int |  | Number of product photos | 6 |
| `weight_g` | int |  | Product weight in grams | 300 |
| `length_cm` | int |  | Package length (cm) | 20 |
| `height_cm` | int |  | Package height (cm) | 16 |
| `width_cm` | int |  | Package width (cm) | 16 |

### `orders` (table)
One row per order with derived delivery/SLA fields

| Column | Type | Key / null | Meaning | Example |
|---|---|---|---|---|
| `order_id` | char(32) | PK NOT NULL | Order key | 00010242fe8c5a6d1ba2dd792cb16214 |
| `customer_id` | char(32) | index/FK NOT NULL | Customer key PER ORDER (one per order - not the person) | 3ce436f183e68e07877b285a838db11a |
| `order_status` | varchar(20) | index/FK NOT NULL | Order status (delivered, shipped, canceled, unavailable, invoiced, processing, created, approved) | delivered |
| `purchase_ts` | datetime | index/FK NOT NULL | Purchase timestamp | 2017-09-13 08:59:02 |
| `approved_ts` | datetime |  | Payment approval timestamp | 2017-09-13 09:45:35 |
| `carrier_ts` | datetime |  | Handed to the carrier | 2017-09-19 18:34:16 |
| `delivered_ts` | datetime |  | Delivered to the customer | 2017-09-20 23:43:48 |
| `estimated_date` | date |  | Delivery date promised to the customer at purchase | 2017-09-29 |
| `delivery_days` | int |  | Delivered date - purchase date in days (valid deliveries only) | 7 |
| `delay_days` | int |  | Delivered date - promised date; > 0 = late (valid deliveries only) | -9 |
| `is_late` | tinyint(1) |  | 1 if delay_days > 0, 0 if on time/early, NULL if not a valid delivery | 0 |
| `ts_anomaly` | tinyint(1) | NOT NULL | 1 if timestamps are out of logical order (rule R11) | 0 |
| `is_valid_delivery` | tinyint(1) | NOT NULL | 1 = delivered, has a delivery date and no timestamp anomaly | 1 |

### `order_items` (table)
Order lines: one row per item (the GMV grain)

| Column | Type | Key / null | Meaning | Example |
|---|---|---|---|---|
| `order_id` | char(32) | PK NOT NULL | Order key | 00010242fe8c5a6d1ba2dd792cb16214 |
| `order_item_id` | int | PK NOT NULL | Line number inside the order (1..n) | 1 |
| `product_id` | char(32) | index/FK NOT NULL | Product key | 4244733e06e7ecb4970a6e2683c13e61 |
| `seller_id` | char(32) | index/FK NOT NULL | Seller key | 48436dade18ac8b2bce089ec2a041202 |
| `shipping_limit_ts` | datetime |  | Deadline for the seller to hand the item to the carrier | 2017-09-19 09:45:35 |
| `price` | decimal(10,2) | NOT NULL | Item price (R$) | 58.90 |
| `freight_value` | decimal(10,2) | NOT NULL | Freight charged for the item (R$) | 13.29 |

### `order_payments` (table)
Payments per order (several rows when vouchers/cards are combined)

| Column | Type | Key / null | Meaning | Example |
|---|---|---|---|---|
| `order_id` | char(32) | PK NOT NULL | Order key | 00010242fe8c5a6d1ba2dd792cb16214 |
| `payment_sequential` | int | PK NOT NULL | Payment number inside the order (1..n) | 1 |
| `payment_type` | varchar(20) | index/FK NOT NULL | credit_card, boleto, voucher or debit_card | credit_card |
| `payment_installments` | int | NOT NULL | Number of instalments (0 in source set to 1, rule R10) | 2 |
| `payment_value` | decimal(10,2) | NOT NULL | Amount paid with this payment (R$) | 72.19 |

### `order_reviews` (table)
Latest review per order (review text dropped; only has_comment kept)

| Column | Type | Key / null | Meaning | Example |
|---|---|---|---|---|
| `review_id` | char(32) | NOT NULL | Review key (not unique across orders in the source) | 97ca439bc427b48bc1cd7177abe71365 |
| `order_id` | char(32) | PK NOT NULL | Order key | 00010242fe8c5a6d1ba2dd792cb16214 |
| `review_score` | tinyint | NOT NULL | 1-5 stars | 5 |
| `has_comment` | tinyint(1) |  | 1 if the review had a title or message | 1 |
| `review_created_date` | date |  | Date the review survey was sent/created | 2017-09-21 |
| `review_answer_ts` | datetime |  | When the customer answered | 2017-09-22 10:57:03 |

### `seller_leads` (table)
Marketing-qualified seller leads joined to closed deals

| Column | Type | Key / null | Meaning | Example |
|---|---|---|---|---|
| `mql_id` | char(32) | PK NOT NULL | Marketing-qualified lead key | 0002ac0d783338cfeab0b2bdbd872cda |
| `first_contact_date` | date | NOT NULL | Date the lead first contacted Olist | 2017-11-14 |
| `landing_page_id` | char(32) |  | Landing page the lead came through | b76ef37428e6799c421989521c0e5077 |
| `origin` | varchar(30) | NOT NULL | Acquisition channel of the lead ('unknown' if blank) | unknown |
| `is_won` | tinyint(1) | NOT NULL | 1 if the lead signed a contract (closed deal exists) | 0 |
| `seller_id` | char(32) | index/FK | Seller key |  |
| `won_date` | date |  | Contract date |  |
| `business_segment` | varchar(60) |  | Seller's declared business segment |  |
| `lead_type` | varchar(30) |  | Lead size/type (online_medium, industry, ...) |  |
| `business_type` | varchar(30) |  | reseller / manufacturer / other |  |
| `days_to_close` | int |  | won_date - first_contact_date |  |

## Star schema (sql/setup/09_star_schema_views.sql)

### `dim_date` (table)
Calendar 2016-09-01..2018-12-31 built with a recursive CTE (Power BI date table)

| Column | Type | Key / null | Meaning | Example |
|---|---|---|---|---|
| `date` | date | PK NOT NULL | Calendar day | 2016-09-01 |
| `year` | smallint | NOT NULL | Calendar year | 2016 |
| `quarter` | tinyint | NOT NULL | Quarter 1-4 | 3 |
| `month_num` | tinyint | NOT NULL | Month 1-12 | 9 |
| `month_name` | varchar(9) | NOT NULL | Month name (sort by month_num) | September |
| `month_start` | date | NOT NULL | First day of the month | 2016-09-01 |
| `year_month` | char(7) | NOT NULL | Month label 'YYYY-MM' | 2016-09 |
| `week_start` | date | NOT NULL | Monday of the ISO week | 2016-08-29 |
| `day_of_week_num` | tinyint | NOT NULL | 1 = Monday ... 7 = Sunday | 4 |
| `day_name` | varchar(9) | NOT NULL | Weekday name | Thursday |
| `is_weekend` | tinyint(1) | NOT NULL | 1 = Saturday/Sunday | 0 |
| `in_window` | tinyint(1) | NOT NULL | 1 if the day is inside the analysis window | 0 |

### `v_valid_orders` (view)


| Column | Type | Key / null | Meaning | Example |
|---|---|---|---|---|
| `order_id` | char(32) | NOT NULL | Order key | 00010242fe8c5a6d1ba2dd792cb16214 |
| `customer_id` | char(32) | NOT NULL | Customer key PER ORDER (one per order - not the person) | 3ce436f183e68e07877b285a838db11a |
| `customer_unique_id` | char(32) | NOT NULL | The actual person; use for repeat, cohorts, RFM | 871766c5855e863f6eccc05f988b23cb |
| `order_status` | varchar(20) | NOT NULL | Order status (delivered, shipped, canceled, unavailable, invoiced, processing, created, approved) | delivered |
| `purchase_ts` | datetime | NOT NULL | Purchase timestamp | 2017-09-13 08:59:02 |
| `purchase_date` | date |  | Purchase date (relationship key to dim_date) | 2017-09-13 |
| `estimated_date` | date |  | Delivery date promised to the customer at purchase | 2017-09-29 |
| `delivered_ts` | datetime |  | Delivered to the customer | 2017-09-20 23:43:48 |
| `is_valid_delivery` | tinyint(1) | NOT NULL | 1 = delivered, has a delivery date and no timestamp anomaly | 1 |
| `is_late` | tinyint(1) |  | 1 if delay_days > 0, 0 if on time/early, NULL if not a valid delivery | 0 |
| `delivery_days` | int |  | Delivered date - purchase date in days (valid deliveries only) | 7 |
| `delay_days` | int |  | Delivered date - promised date; > 0 = late (valid deliveries only) | -9 |
| `delay_bucket` | varchar(20) |  | fn_delay_bucket(delay_days): 1. Early 7+ d ... 5. Late 8+ d / Not delivered | 1. Early 7+ d |
| `review_score` | tinyint |  | 1-5 stars | 5 |
| `is_low_review` | int |  | 1 if review_score <= 2, 0 otherwise, NULL if no review | 0 |
| `has_voucher` | bigint | NOT NULL | 1 if any payment of the order used a voucher | 0 |
| `payment_type_main` | varchar(20) |  | Payment type with the largest value in the order | credit_card |
| `max_installments` | bigint |  | Highest number of instalments among the order's payments | 2 |
| `n_items` | bigint | NOT NULL | Items in the order | 1 |
| `merchandise_value` | decimal(32,2) |  | Sum of item prices (R$) | 58.90 |
| `freight_value` | decimal(32,2) |  | Freight charged for the item (R$) | 13.29 |
| `order_gmv` | decimal(33,2) |  | Order GMV = items price + freight (R$) | 72.19 |

### `v_fact_order_items` (view)


| Column | Type | Key / null | Meaning | Example |
|---|---|---|---|---|
| `order_id` | char(32) | NOT NULL | Order key | 00010242fe8c5a6d1ba2dd792cb16214 |
| `order_item_id` | int | NOT NULL | Line number inside the order (1..n) | 1 |
| `purchase_date` | date |  | Purchase date (relationship key to dim_date) | 2017-09-13 |
| `customer_unique_id` | char(32) | NOT NULL | The actual person; use for repeat, cohorts, RFM | 871766c5855e863f6eccc05f988b23cb |
| `seller_id` | char(32) | NOT NULL | Seller key | 48436dade18ac8b2bce089ec2a041202 |
| `product_id` | char(32) | NOT NULL | Product key | 4244733e06e7ecb4970a6e2683c13e61 |
| `price` | decimal(10,2) | NOT NULL | Item price (R$) | 58.90 |
| `freight_value` | decimal(10,2) | NOT NULL | Freight charged for the item (R$) | 13.29 |
| `item_gmv` | decimal(11,2) | NOT NULL | price + freight_value for this item (R$) | 72.19 |
| `order_status` | varchar(20) | NOT NULL | Order status (delivered, shipped, canceled, unavailable, invoiced, processing, created, approved) | delivered |
| `is_valid_delivery` | tinyint(1) | NOT NULL | 1 = delivered, has a delivery date and no timestamp anomaly | 1 |
| `is_late` | tinyint(1) |  | 1 if delay_days > 0, 0 if on time/early, NULL if not a valid delivery | 0 |
| `delivery_days` | int |  | Delivered date - purchase date in days (valid deliveries only) | 7 |
| `delay_days` | int |  | Delivered date - promised date; > 0 = late (valid deliveries only) | -9 |
| `delay_bucket` | varchar(20) |  | fn_delay_bucket(delay_days): 1. Early 7+ d ... 5. Late 8+ d / Not delivered | 1. Early 7+ d |
| `review_score` | tinyint |  | 1-5 stars | 5 |
| `is_low_review` | int |  | 1 if review_score <= 2, 0 otherwise, NULL if no review | 0 |
| `has_voucher` | bigint | NOT NULL | 1 if any payment of the order used a voucher | 0 |
| `payment_type_main` | varchar(20) |  | Payment type with the largest value in the order | credit_card |
| `max_installments` | bigint |  | Highest number of instalments among the order's payments | 2 |
| `distance_km` | double |  | Great-circle distance seller zip -> customer zip (ST_Distance_Sphere), NULL if a zip lacks geo | 301.5 |
| `seller_region` | varchar(15) |  | Region of the seller | Southeast |
| `customer_region` | varchar(15) |  | Region of the customer (order address) | Southeast |

### `v_dim_customer` (view)


| Column | Type | Key / null | Meaning | Example |
|---|---|---|---|---|
| `customer_unique_id` | char(32) | NOT NULL | The actual person; use for repeat, cohorts, RFM | 0000366f3b9a7992bf8c76cfdf3221e2 |
| `state` | char(2) | NOT NULL | Brazilian state code (UF), 2 letters | SP |
| `region` | varchar(15) |  | Brazilian macro-region derived from state (fn_region) | Southeast |
| `city_clean` | varchar(80) |  | City lower-cased, accents/apostrophes/hyphens removed (fn_strip_accents) | cajamar |
| `first_order_ts` | datetime | NOT NULL | Timestamp of the person's first valid order | 2018-05-10 10:56:27 |
| `first_order_month` | varchar(7) |  | 'YYYY-MM' of the first valid order (cohort) | 2018-05 |
| `first_order_id` | char(32) | NOT NULL | Order id of the first valid order | e22acc9c116caa3f2b7121bbb380d08e |
| `first_order_is_late` | tinyint(1) |  | is_late of the first order (NULL = not a valid delivery) | 0 |
| `first_order_has_voucher` | bigint | NOT NULL | 1 if the first order used a voucher | 0 |
| `first_order_value` | decimal(33,2) |  | GMV of the first order (R$) | 141.90 |
| `total_orders` | bigint | NOT NULL | Valid orders of the person in the window | 1 |
| `total_gmv` | decimal(55,2) |  | GMV of all those orders (R$) | 141.90 |
| `eligible_repeat` | int | NOT NULL | 1 if first order <= window_end - 180 days (full repeat horizon observed) | 0 |
| `repeat_180d` | int | NOT NULL | 1 if a later-day valid order followed within 180 days | 0 |
| `rfm_segment` | varchar(20) | NOT NULL | RFM segment (see a13): Champions, Loyal - lapsing, New - high/low value, At risk - high value, Hibernating, Lost | New - high value |

### `v_dim_seller` (view)


| Column | Type | Key / null | Meaning | Example |
|---|---|---|---|---|
| `seller_id` | char(32) | NOT NULL | Seller key | 0015a82c2db000af6aaaf3ae2ecb0532 |
| `state` | char(2) | NOT NULL | Brazilian state code (UF), 2 letters | SP |
| `region` | varchar(15) |  | Brazilian macro-region derived from state (fn_region) | Southeast |
| `city_clean` | varchar(80) |  | City lower-cased, accents/apostrophes/hyphens removed (fn_strip_accents) | santo andre |
| `first_sale_month` | varchar(7) |  | 'YYYY-MM' of the seller's first valid sale | 2017-09 |
| `last_sale_month` | varchar(7) |  | 'YYYY-MM' of the last valid sale | 2017-10 |
| `lead_origin` | varchar(30) |  | Acquisition channel if the seller came through the marketing funnel |  |
| `is_acquired_via_funnel` | int | NOT NULL | 1 if the seller matches a won lead | 0 |

### `v_dim_product` (view)


| Column | Type | Key / null | Meaning | Example |
|---|---|---|---|---|
| `product_id` | char(32) | NOT NULL | Product key | 00066f42aeeb9f3007548bb9d3f33c38 |
| `category_en` | varchar(80) | NOT NULL | Product category in English (Portuguese kept when no translation exists) | perfumery |
| `weight_g` | int |  | Product weight in grams | 300 |
| `volume_cm3` | bigint |  | length x height x width (cm3) | 5120 |
| `photos_qty` | int |  | Number of product photos | 6 |

### `v_fact_seller_leads` (view)


| Column | Type | Key / null | Meaning | Example |
|---|---|---|---|---|
| `mql_id` | char(32) | NOT NULL | Marketing-qualified lead key | 0002ac0d783338cfeab0b2bdbd872cda |
| `first_contact_date` | date | NOT NULL | Date the lead first contacted Olist | 2017-11-14 |
| `origin` | varchar(30) | NOT NULL | Acquisition channel of the lead ('unknown' if blank) | unknown |
| `landing_page_id` | char(32) |  | Landing page the lead came through | b76ef37428e6799c421989521c0e5077 |
| `is_won` | tinyint(1) | NOT NULL | 1 if the lead signed a contract (closed deal exists) | 0 |
| `won_date` | date |  | Contract date |  |
| `days_to_close` | int |  | won_date - first_contact_date |  |
| `business_segment` | varchar(60) |  | Seller's declared business segment |  |
| `lead_type` | varchar(30) |  | Lead size/type (online_medium, industry, ...) |  |
| `seller_id` | char(32) |  | Seller key |  |
| `first_sale_date` | date |  | Date of the seller's first valid sale |  |
| `made_first_sale` | int | NOT NULL | 1 if the won seller ever sold | 0 |
| `gmv_first_90d` | decimal(33,2) | NOT NULL | Seller GMV in the 90 days starting at its first sale (R$) | 0.00 |
| `active_months_first_6` | bigint | NOT NULL | Distinct selling months among the first 6 months after first sale | 0 |
