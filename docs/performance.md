# Performance: indexes, EXPLAIN ANALYZE and SARGability

Source script: [`sql/setup/08_indexes_performance.sql`](../sql/setup/08_indexes_performance.sql) ·
raw output: [`results/perf/08_explain_analyze.txt`](../results/perf/08_explain_analyze.txt) (regenerate with `make perf`).

**Environment:** MySQL 8.4.11 (Homebrew), Apple Silicon Mac, InnoDB with a warm buffer pool
(each table is read once before measuring, so BEFORE and AFTER both run from memory).
Numbers below are from the final clean rebuild (`make clean-db && make all`). Timings vary by about ±10% between runs
(Q5 ranged 24-44 ms across runs). Rows examined is deterministic.

## Method

1. **Baseline.** Only primary keys plus the indexes InnoDB keeps for foreign keys. Every FK column
   needs an index, so `orders.customer_id`, `order_items.seller_id` and `order_items.product_id`
   are indexed implicitly (`fk_orders_customer`, `fk_items_seller`, `fk_items_product`). 08 drops the other
   secondary indexes (idempotent helper procedures `sp_drop_index_if_exists` / `sp_create_index_if_missing`
   use `information_schema.statistics` + `PREPARE/EXECUTE`, because MySQL has no `DROP INDEX IF EXISTS`).
2. Run every benchmark with `EXPLAIN ANALYZE`, which executes the query and reports the **actual time** of
   each plan node.
3. Create the 8 indexes from the spec, then `ANALYZE TABLE` to refresh statistics.
4. Re-run the identical queries.

**Actual time** is the top plan node's time until the last row (ms).
**Rows examined** is the increase of the session's `Handler_read_*` counters during the query
(rows the storage engine handed to the SQL layer, including internal temp-table reads), minus the
small cost of reading the counters themselves.

## Results

| # | Query | Before: time (ms) | After: time (ms) | Before: rows examined | After: rows examined | What changed in the plan |
|---|---|---:|---:|---:|---:|---|
| Q1 | **a04 lane SLA** (valid deliveries per seller→customer state, full window) | 1,138 | 1,141 | 861,482 | 861,482 | Nothing material: still scans `orders`, joins by PK, dedups in a temp table |
| Q2 | **a11 cohorts** (first-order month × activity month, full window) | 1,603 | 1,587 | 1,246,570 | 1,246,570 | Nothing material: scan + temp-table GROUP BY |
| Q3 | One customer's order history (`customer_unique_id = ?`) | 25.0 | 0.36 | 99,478 | 52 | Full scan of `customers` → index lookup `idx_customers_unique_id` |
| Q4 | Orders in one week (`purchase_ts` range) | 23.3 | 0.45 | 99,444 | 1,644 | Full scan → covering index range scan `idx_orders_purchase_ts` |
| Q5 | Voucher payments (`payment_type = 'voucher'`) | 24.3 | 1.39 | 103,886 | 5,776 | Full scan → index lookup `idx_payments_type` |
| Q6 | Lead record of one seller (`seller_id = ?`) | 2.73 | 0.020 | 8,003 | 2 | Full scan → index lookup `idx_leads_seller` |

### How to read this

* **Indexes do not speed up the two "slow" analytical queries (a04, a11).** Both need nearly every
  order in the 20-month window (about 95k of 99k orders). Reading the whole table sequentially is
  already the cheapest plan, and the optimizer keeps choosing it. Their cost is the join, the de-duplication
  and the GROUP BY temp tables, not finding rows. At warehouse scale you'd fix this with
  **pre-aggregation**, which is exactly what the `mart_*` tables do. `mart_lane_sla` turns the lane
  question into a 410-row table read.
* **Indexes win on selective predicates.** These are the drill-downs a dashboard or app makes, e.g. "this
  customer", "this week", "this seller". They run 17–134× faster and touch 18× to 4,000× fewer rows.
* **Trade-off.** Each index costs disk space and slows every INSERT/UPDATE on that table, since the B-tree
  must be maintained. Here the data is loaded once in batch, so the read benefit wins.
* **Implicit FK indexes.** After `CREATE INDEX idx_orders_customer_id ON orders(customer_id)`, InnoDB
  silently dropped its implicit `fk_orders_customer` index, because the new index can serve the FK
  (visible in the "INDEXES AFTER" listing in the raw output). The same happened for `fk_items_seller` and
  `fk_items_product`. Performance is the same; the names are clearer.

## SARGability

A predicate is SARGable (Search-ARGument-able) when it compares the **bare indexed column** with
constants, so the B-tree can **seek** to the first matching entry and stop after the last one.

| Predicate | EXPLAIN `type` | Key / access | Rows read | Actual time (ms) |
|---|---|---|---:|---:|
| `WHERE YEAR(purchase_ts) = 2018` | `index` (full index scan) | `idx_orders_purchase_ts`, `YEAR()` evaluated per entry | 99,441 | 19.9 |
| `WHERE purchase_ts >= '2018-01-01' AND purchase_ts < '2019-01-01'` | `range` | `idx_orders_status_purchase` (skip scan) | 54,011 | 22.5 |
| `WHERE DATE_FORMAT(purchase_ts,'%Y-%m') = '2018-03'` | full covering index scan | `idx_orders_purchase_ts`, function per entry | 99,441 | 25.1 |
| `WHERE purchase_ts >= '2018-03-01' AND purchase_ts < '2018-04-01'` | `range` | covering range scan `idx_orders_purchase_ts` | 7,211 | 2.0 |

* `YEAR(purchase_ts)` hides the column inside a function. The index is sorted by `purchase_ts`, not by
  `YEAR(purchase_ts)`, so MySQL must visit **every** entry and compute `YEAR()` on each one.
* The range form lets MySQL jump straight to 2018-01-01. For a whole year (54% of all orders) the gain is
  small, since half the index is read either way. For a single month the SARGable version is **13× faster**
  and reads 7,211 instead of 99,441 entries.
* Rule used in every analysis file: filter dates as `ts >= start AND ts < end_exclusive`, never
  `YEAR(ts) = …` or `DATE(ts) = …`. (MySQL 8 could also index an expression, `CREATE INDEX … ((YEAR(ts)))`,
  but rewriting the predicate is simpler and works with the existing index.)
