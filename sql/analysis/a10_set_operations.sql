/* ============================================================================
   File        : a10_set_operations.sql
   Purpose     : Set logic on customers and sellers, using native EXCEPT / INTERSECT
                 (MySQL 8.0.31+) next to the classic join-based equivalents.
   Business Q  : Who bought in 2017 but not 2018? Which sellers were active in both H1-2017
                 and H1-2018? How much do UNION and UNION ALL differ?
   SQL concepts: EXCEPT, INTERSECT, UNION vs UNION ALL, NOT EXISTS (EXCEPT equivalent),
                 INNER JOIN of DISTINCT sets (INTERSECT equivalent), derived tables
   Output      : lapsed_2017_customers, sellers_active_both_h1, union_vs_union_all
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/analysis/a10_set_operations.sql
   ========================================================================== */

SET @we_excl = CAST(fn_cfg('window_end') AS DATE) + INTERVAL 1 DAY;   -- 2018 ends at window end

-- @query: lapsed_2017_customers
WITH buyers_2017 AS (              -- customers (people) with a valid order in 2017
  SELECT DISTINCT c.customer_unique_id
  FROM orders AS o
  INNER JOIN customers AS c ON c.customer_id = o.customer_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= '2017-01-01' AND o.purchase_ts < '2018-01-01'
),
buyers_2018 AS (
  SELECT DISTINCT c.customer_unique_id
  FROM orders AS o
  INNER JOIN customers AS c ON c.customer_id = o.customer_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= '2018-01-01' AND o.purchase_ts < @we_excl
)
SELECT 'EXCEPT' AS method,
       (SELECT COUNT(*) FROM (SELECT customer_unique_id FROM buyers_2017
                              EXCEPT
                              SELECT customer_unique_id FROM buyers_2018) AS lapsed) AS lapsed_customers,
       (SELECT COUNT(*) FROM buyers_2017)                                            AS buyers_2017
UNION ALL
SELECT 'NOT EXISTS',
       (SELECT COUNT(*) FROM buyers_2017 AS b17
        WHERE NOT EXISTS (SELECT 1 FROM buyers_2018 AS b18
                          WHERE b18.customer_unique_id = b17.customer_unique_id)),
       (SELECT COUNT(*) FROM buyers_2017);
-- Reading the result: EXCEPT and NOT EXISTS agree: 42,370 of the 43,034 people who bought in 2017 did not buy
--   again in Jan-Aug 2018.

-- @query: sellers_active_both_h1
WITH sellers_h1_2017 AS (          -- sellers with a valid sale in Jan-Jun 2017
  SELECT DISTINCT oi.seller_id
  FROM order_items AS oi
  INNER JOIN orders AS o ON o.order_id = oi.order_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= '2017-01-01' AND o.purchase_ts < '2017-07-01'
),
sellers_h1_2018 AS (
  SELECT DISTINCT oi.seller_id
  FROM order_items AS oi
  INNER JOIN orders AS o ON o.order_id = oi.order_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= '2018-01-01' AND o.purchase_ts < '2018-07-01'
)
SELECT 'INTERSECT' AS method,
       (SELECT COUNT(*) FROM (SELECT seller_id FROM sellers_h1_2017
                              INTERSECT
                              SELECT seller_id FROM sellers_h1_2018) AS both_periods) AS sellers_in_both,
       (SELECT COUNT(*) FROM sellers_h1_2017) AS sellers_h1_2017,
       (SELECT COUNT(*) FROM sellers_h1_2018) AS sellers_h1_2018
UNION ALL
SELECT 'INNER JOIN',
       (SELECT COUNT(*) FROM sellers_h1_2017 AS a
        INNER JOIN sellers_h1_2018 AS b ON b.seller_id = a.seller_id),
       (SELECT COUNT(*) FROM sellers_h1_2017),
       (SELECT COUNT(*) FROM sellers_h1_2018);
-- Reading the result: INTERSECT and INNER JOIN agree: 505 sellers were active in both H1-2017 (970 sellers)
--   and H1-2018 (1,994 sellers). The seller base doubled, but only about half of the H1-2017 sellers were
--   still selling a year later.

-- @query: union_vs_union_all
WITH buyers_2017 AS (
  SELECT DISTINCT c.customer_unique_id
  FROM orders AS o
  INNER JOIN customers AS c ON c.customer_id = o.customer_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= '2017-01-01' AND o.purchase_ts < '2018-01-01'
),
buyers_2018 AS (
  SELECT DISTINCT c.customer_unique_id
  FROM orders AS o
  INNER JOIN customers AS c ON c.customer_id = o.customer_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= '2018-01-01' AND o.purchase_ts < @we_excl
)
SELECT
  (SELECT COUNT(*) FROM (SELECT customer_unique_id FROM buyers_2017
                         UNION              -- removes duplicates (people who bought in both years)
                         SELECT customer_unique_id FROM buyers_2018) AS u)     AS union_rows,
  (SELECT COUNT(*) FROM (SELECT customer_unique_id FROM buyers_2017
                         UNION ALL          -- keeps duplicates, no sort/dedup step -> cheaper
                         SELECT customer_unique_id FROM buyers_2018) AS ua)    AS union_all_rows,
  (SELECT COUNT(*) FROM (SELECT customer_unique_id FROM buyers_2017
                         INTERSECT
                         SELECT customer_unique_id FROM buyers_2018) AS i)     AS bought_in_both_years;
-- Reading the result: UNION returns 94,707 distinct buyers, UNION ALL 95,371 rows. The 664-row difference is
--   exactly the people who bought in both years (INTERSECT = 664).
