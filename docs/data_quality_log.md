# Data quality log

Sources: `dq_log` written by `sp_load_core()` (exported to
[`results/sql/06_transform_load_core__dq_log.csv`](../results/sql/06_transform_load_core__dq_log.csv)) and the
audit [`results/sql/07_data_quality_audit__data_quality_report.csv`](../results/sql/07_data_quality_audit__data_quality_report.csv).
Regenerate with `make core quality`.

## Load path used

* **`LOAD DATA LOCAL INFILE` (02_load_staging.sql)**, the primary path. All 11 staging tables match the expected row
  counts from the spec **exactly** (0.00% difference, status OK for every table).
* The pandas fallback (`python/load_fallback.py`) was tested on `stg_sellers`, `stg_category_translation` and
  `stg_closed_deals`. It produced identical row counts and identical values (including the backslash city below),
  then the tables were re-loaded with LOAD DATA.

## Issues found while loading (before the rules below)

| Issue | How it was found | Fix |
|---|---|---|
| **Raw backslashes** in 1 seller city (`rio de janeiro \rio de janeiro`) and 7 review rows (one review ends with `:\"`) | `grep -c '\\'` on the CSVs | `ESCAPED BY ''`. With MySQL's default backslash escaping, `\"` would swallow the closing quote and shift every following column, and `\r` would become a carriage return. |
| **Windows line endings (`\r\n`)** in `product_category_name_translation.csv` and `olist_order_reviews_dataset.csv` | Not flagged by macOS `file`. Found when pandas quoted every English category name in a result CSV (a hidden trailing `\r`). Confirmed with `tr -cd '\r' < file \| wc -c` = 71 and 104,720 | `LINES TERMINATED BY '\r\n'` for those two files, plus a permanent audit check `text_values_with_control_chars` (must be 0) |
| UTF-8 BOM on the translation file's header | `head -c 3 \| xxd` → `efbbbf` | Sits on the header line, so `IGNORE 1 LINES` drops it (pandas: `encoding='utf-8-sig'`) |

## Cleaning rules R01-R17 (counts from `dq_log`)

| Rule | Table | Issue | Treatment | Rows affected |
|---|---|---|---|---:|
| R01 | customers / sellers / geo | Zip prefixes losing leading zeros | `LPAD(TRIM(x),5,'0')` everywhere | **0** (this Kaggle version ships zero-padded, quoted zips; rule kept as a guard) |
| R02 | orders | Empty strings in timestamp columns | `NULLIF(TRIM(x),'')` before `STR_TO_DATE` | 4,908 empty timestamps → NULL |
| R02 | products | Empty numeric attributes | `NULLIF` before `CAST` | 611 products |
| R03 | geolocation_zip | ~1M points, several per zip, some outside Brazil | keep lat −34..6 / lng −74..−34; AVG lat/lng; mode city via `ROW_NUMBER` on counts | 42 points dropped; 19,010 zip prefixes |
| R04 | customers / sellers | Inconsistent city spelling | `city_clean = fn_strip_accents(city)` | 450 customer rows, 14 seller rows changed |
| R05 | products | Misspelled source columns `*_lenght` | renamed to `name_length`, `description_length` | 32,951 rows |
| R06 | products | Missing category | `sem_categoria` / `unknown` | 610 products |
| R07 | products | Category without English translation | `COALESCE(translation, category_pt)` | 13 products: `pc_gamer`, `portateis_cozinha_e_preparadores_de_alimentos` |
| R08 | order_reviews | Several reviews per order; review_id reused | keep latest per order: `ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY review_answer_ts DESC, review_created_date DESC, review_id DESC) = 1` | 551 duplicate rows removed; 789 review_ids reused across orders (info) |
| R09 | order_payments | `payment_type = 'not_defined'` | deleted (`DELETE` + `ROW_COUNT()`) | 3 |
| R10 | order_payments | `payment_installments = 0` | set to 1 (CHECK requires ≥ 1) | 2 |
| R11 | orders | Timestamps out of order | `ts_anomaly = 1`, kept but excluded from SLA metrics | 1,382 orders |
| R12 | orders | Status delivered but no delivery date | stays `is_valid_delivery = 0` | 8 |
| R13 | orders | Derived SLA fields | only for delivered + dated + no anomaly | 95,097 valid deliveries |
| R14 | seller_leads | Blank origin | `'unknown'` | 60 |
| R15 | seller_leads | Won flag, days to close | `is_won` = closed deal exists; `DATEDIFF(won_date, first_contact_date)` | 842 won |
| R16 | order_items | Non-positive price | excluded | 0 |
| R17 | customers / sellers | Region | `fn_region(state)`; check for `Unknown` | 0 unknown |

Rows loaded to core: customers 99,441 · sellers 3,095 · products 32,951 · orders 99,441 · order_items 112,650 ·
order_payments 103,883 · order_reviews 98,673 · seller_leads 8,000 · category_translation 71 · geolocation_zip 19,010.

## Transaction safety (proved, not assumed)

`sp_load_core()` runs the whole transform inside `START TRANSACTION … COMMIT` with
`DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END`, and empties core with `DELETE`. It doesn't use
`TRUNCATE`, which is DDL and would commit implicitly. Test: a staging order with `order_status = 'bogus_status'` was planted
and the procedure called. It failed with `ERROR 3819: Check constraint 'chk_orders_status' is violated` *after*
it had already deleted and re-inserted earlier tables. Afterwards core still held the previous complete load (99,441 orders,
112,650 items, 29 log rows). Evidence: [`results/sql/06_transform_load_core__rollback_test.csv`](../results/sql/06_transform_load_core__rollback_test.csv).

## Audit results (07_data_quality_audit.sql): 33 PASS · 1 WARN · 0 FAIL

| Check | Result |
|---|---|
| Row counts core vs staging (after documented exclusions), 10 tables | all PASS |
| Primary-key uniqueness, 10 tables | all PASS (0 duplicate keys) |
| Orphan foreign keys (item→order/product/seller, payment→order, review→order, order→customer) | all 0, PASS |
| % orders with timestamp anomaly | **1.39% → WARN** (threshold 1%), explained below |
| % delivered orders without delivery date | 0.008%, PASS |
| Valid deliveries with negative delivery days / missing promise date | 0, PASS |
| % customers whose zip has no geolocation | 0.281%, PASS (distance_km is NULL for them) |
| Items vs payments gap (non-canceled orders having both) | 0.018%, PASS (threshold 2%) |
| Control characters in key text fields | 0, PASS |
| Max order ids per customer_unique_id | 17 (info) |
| order_status values outside the CHECK list | 0, PASS |

**The WARN, explained.** 1,382 orders (1.39%) have timestamps out of logical order. Almost all are a carrier hand-off
recorded *before* payment approval; the rest are deliveries recorded before the carrier hand-off. These are source-system recording quirks: the orders exist and were paid, so they **stay in GMV and order
counts** but are excluded from delivery-time metrics (`is_valid_delivery = 0`). The cost is that 1.4% of deliveries
are missing from SLA statistics, which is small and not concentrated in any month.

## Other decisions worth knowing

* **5 orders with no items** (statuses created/invoiced/shipped) are excluded from "valid orders", so SQL and Power BI
  (item-grain fact) count orders identically (97,905).
* **772 orders have payments but no items**, all canceled/unavailable. They sit outside the GMV base (a08).
* **Reviews:** text is dropped (`has_comment` kept), because the analysis needs scores, not free text.
* **`seller_leads.seller_id` is not a foreign key**: only 379 of 842 won sellers made a valid sale in the window
  (a16), so most won sellers are absent from `sellers`/orders and an FK would reject them.
