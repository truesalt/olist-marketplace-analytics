/* ============================================================================
   File        : a18_categories_and_strings.sql
   Purpose     : Top categories (with readable English labels) and top-3 customer cities in
                 every state; show how much city-name cleaning merges spelling variants.
   Business Q  : Which categories and cities lead each state?
   SQL concepts: LEFT JOIN translation + COALESCE fallback, string functions (LOWER, TRIM,
                 REPLACE, UPPER, SUBSTRING, CONCAT, CHAR_LENGTH), fn_strip_accents,
                 ROW_NUMBER top-N per group (QUALIFY substitute), COLLATE utf8mb4_bin vs the
                 accent-insensitive default collation
   Output      : top_categories, top_cities_per_state, city_name_cleanup_effect
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/analysis/a18_categories_and_strings.sql
   ========================================================================== */

SET @ws      = CAST(fn_cfg('window_start') AS DATE);
SET @we_excl = CAST(fn_cfg('window_end') AS DATE) + INTERVAL 1 DAY;

-- @query: top_categories
WITH category_sales AS (         -- GMV by the ORIGINAL Portuguese category
  SELECT p.category_pt,
         COUNT(DISTINCT o.order_id)       AS orders,
         SUM(oi.price + oi.freight_value) AS gmv
  FROM order_items AS oi
  INNER JOIN orders   AS o ON o.order_id   = oi.order_id
  INNER JOIN products AS p ON p.product_id = oi.product_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
  GROUP BY p.category_pt
),
labelled AS (                    -- English name if translated, else keep Portuguese (COALESCE)
  SELECT cs.*,
         COALESCE(ct.category_en, cs.category_pt)                         AS category_en,
         REPLACE(LOWER(TRIM(COALESCE(ct.category_en, cs.category_pt))), '_', ' ') AS words
  FROM category_sales AS cs
  LEFT JOIN category_translation AS ct ON ct.category_pt = cs.category_pt
)
SELECT ROW_NUMBER() OVER (ORDER BY gmv DESC, category_en)                AS category_rank,
       category_pt,
       category_en,
       CONCAT(UPPER(SUBSTRING(words, 1, 1)), SUBSTRING(words, 2))       AS display_label,  -- 'Bed bath table'
       orders,
       ROUND(gmv, 2)                                                     AS gmv_brl,
       ROUND(100 * gmv / SUM(gmv) OVER (), 2)                            AS gmv_share_pct
FROM labelled
ORDER BY category_rank
LIMIT 15;
-- Reading the result: health_beauty (R$1,432,213; 9.13%), watches_gifts (R$1,294,824) and bed_bath_table
--   (R$1,239,780, the most orders: 9,394) lead. display_label shows REPLACE + UPPER + SUBSTRING.

-- @query: top_cities_per_state
WITH city_orders AS (            -- orders per cleaned customer city
  SELECT c.state, c.city_clean, COUNT(*) AS orders
  FROM orders AS o
  INNER JOIN customers AS c ON c.customer_id = o.customer_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
  GROUP BY c.state, c.city_clean
),
ranked AS (                      -- QUALIFY substitute: rank inside a CTE, filter outside
  SELECT co.*,
         ROW_NUMBER() OVER (PARTITION BY state ORDER BY orders DESC, city_clean) AS city_rank,
         ROUND(100 * orders / SUM(orders) OVER (PARTITION BY state), 1)          AS pct_of_state_orders
  FROM city_orders AS co
)
SELECT state, city_rank, city_clean, orders, pct_of_state_orders
FROM ranked
WHERE city_rank <= 3
ORDER BY state, city_rank;
-- Reading the result: capitals dominate their states: sao paulo is 37.2% of SP orders, rio de janeiro 53.5%
--   of RJ, manaus 94.6% of AM.

-- @query: city_name_cleanup_effect
-- COUNT(DISTINCT city) under the default utf8mb4_0900_ai_ci collation already treats
-- 'São Paulo' and 'sao paulo' as equal; COLLATE utf8mb4_bin counts exact byte strings.
SELECT 'customers'                                         AS source_table,
       COUNT(DISTINCT city COLLATE utf8mb4_bin)            AS distinct_raw_exact,
       COUNT(DISTINCT city)                                AS distinct_raw_accent_insensitive,
       COUNT(DISTINCT city_clean COLLATE utf8mb4_bin)      AS distinct_after_fn_strip_accents,
       COUNT(DISTINCT city COLLATE utf8mb4_bin)
         - COUNT(DISTINCT city_clean COLLATE utf8mb4_bin)  AS variants_merged
FROM customers
UNION ALL
SELECT 'sellers',
       COUNT(DISTINCT city COLLATE utf8mb4_bin),
       COUNT(DISTINCT city),
       COUNT(DISTINCT city_clean COLLATE utf8mb4_bin),
       COUNT(DISTINCT city COLLATE utf8mb4_bin) - COUNT(DISTINCT city_clean COLLATE utf8mb4_bin)
FROM sellers
UNION ALL
SELECT 'stg_geolocation (raw 1M points)',
       COUNT(DISTINCT geolocation_city COLLATE utf8mb4_bin),
       COUNT(DISTINCT geolocation_city),
       COUNT(DISTINCT fn_strip_accents(geolocation_city) COLLATE utf8mb4_bin),
       COUNT(DISTINCT geolocation_city COLLATE utf8mb4_bin)
         - COUNT(DISTINCT fn_strip_accents(geolocation_city) COLLATE utf8mb4_bin)
FROM stg_geolocation;
-- Reading the result: customer and seller city names were already almost clean (4,119 -> 4,113 and 611 -> 606
--   distinct). The raw geolocation table has 8,010 exact spellings; the accent-insensitive collation alone
--   merges them to 5,969, and fn_strip_accents to 5,934 (2,076 variants merged).
