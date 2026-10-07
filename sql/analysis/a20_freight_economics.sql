/* ============================================================================
   File        : a20_freight_economics.sql
   Purpose     : How freight cost scales with distance, product weight and region, and how
                 far categories / bands sit from the marketplace average.
   Business Q  : Is freight hurting conversion-sensitive categories and remote regions?
   SQL concepts: ST_Distance_Sphere(POINT(lng,lat), POINT(lng,lat)) (Haversine substitute),
                 CASE distance / weight bands, ratio metrics, scalar subquery for the overall
                 average, GROUP BY ... WITH ROLLUP subtotals + GROUPING() labels, HAVING
   Output      : freight_by_distance_band, freight_by_category, freight_rollup_region
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist < sql/analysis/a20_freight_economics.sql
   Note        : item-level metrics (freight is charged per item); delivery/late figures here
                 are therefore item-weighted.
   ========================================================================== */

SET @ws      = CAST(fn_cfg('window_start') AS DATE);
SET @we_excl = CAST(fn_cfg('window_end') AS DATE) + INTERVAL 1 DAY;

-- @query: freight_by_distance_band
WITH item_freight AS (           -- valid-order items with seller->customer distance
  SELECT oi.price, oi.freight_value, o.is_valid_delivery, o.is_late, o.delivery_days,
         ST_Distance_Sphere(POINT(sg.lng, sg.lat), POINT(cg.lng, cg.lat)) / 1000 AS distance_km
  FROM order_items AS oi
  INNER JOIN orders    AS o  ON o.order_id    = oi.order_id
  INNER JOIN customers AS c  ON c.customer_id = o.customer_id
  INNER JOIN sellers   AS s  ON s.seller_id   = oi.seller_id
  LEFT JOIN geolocation_zip AS sg ON sg.zip_prefix = s.zip_prefix
  LEFT JOIN geolocation_zip AS cg ON cg.zip_prefix = c.zip_prefix
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
),
banded AS (
  SELECT f.*,
         CASE WHEN distance_km IS NULL THEN '6. unknown (zip not geocoded)'
              WHEN distance_km <  100  THEN '1. < 100 km'
              WHEN distance_km <  300  THEN '2. 100-299 km'
              WHEN distance_km <  700  THEN '3. 300-699 km'
              WHEN distance_km < 1500  THEN '4. 700-1499 km'
              ELSE                          '5. 1500+ km'
         END AS distance_band
  FROM item_freight AS f
)
SELECT distance_band,
       COUNT(*)                                                        AS items,
       ROUND(AVG(distance_km), 0)                                      AS avg_distance_km,
       ROUND(AVG(price), 2)                                            AS avg_price_brl,
       ROUND(AVG(freight_value), 2)                                    AS avg_freight_brl,
       ROUND(100 * SUM(freight_value) / SUM(price), 1)                 AS freight_to_price_pct,
       -- scalar subquery: the marketplace-wide ratio, so each band reads as "+x pp vs average"
       ROUND(100 * SUM(freight_value) / SUM(price)
             - (SELECT 100 * SUM(freight_value) / SUM(price) FROM banded), 1) AS vs_overall_pp,
       ROUND(AVG(CASE WHEN is_valid_delivery = 1 THEN delivery_days END), 1) AS avg_delivery_days,
       ROUND(100 * SUM(CASE WHEN is_late = 1 THEN 1 ELSE 0 END)
             / NULLIF(SUM(is_valid_delivery), 0), 1)                   AS late_pct
FROM banded
GROUP BY distance_band
ORDER BY distance_band;
-- Reading the result: freight rises with distance from 11.8% of item price under 100 km (R$11.75 per item) to
--   22.6% beyond 1,500 km (R$35.78). The same long hauls take 20.5 days vs 6.5 and are late 11.6% vs 4.5% of
--   the time, so remote customers pay more AND wait longer.

-- @query: freight_by_category
WITH item_freight AS (
  SELECT p.category_en, oi.price, oi.freight_value, p.weight_g
  FROM order_items AS oi
  INNER JOIN orders   AS o ON o.order_id   = oi.order_id
  INNER JOIN products AS p ON p.product_id = oi.product_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
)
SELECT category_en,
       COUNT(*)                                                         AS items,
       ROUND(AVG(price), 2)                                             AS avg_price_brl,
       ROUND(AVG(freight_value), 2)                                     AS avg_freight_brl,
       ROUND(AVG(weight_g) / 1000, 2)                                   AS avg_weight_kg,
       ROUND(100 * SUM(freight_value) / SUM(price + freight_value), 1)  AS freight_share_of_gmv_pct,
       ROUND(100 * SUM(freight_value) / SUM(price + freight_value)
             - (SELECT 100 * SUM(freight_value) / SUM(price + freight_value) FROM item_freight), 1)
                                                                        AS vs_overall_pp
FROM item_freight
GROUP BY category_en
HAVING COUNT(*) >= 500                         -- categories with enough volume
ORDER BY freight_share_of_gmv_pct DESC;
-- Reading the result: freight is 22.8% of GMV in electronics (cheap R$57 items), 20.7% in
--   furniture_living_room and 20.0% in office_furniture (heavy, 8-11 kg), +5.8 to +8.5 pp above the overall
--   share. In watches_gifts it is just 7.7%.

-- @query: freight_rollup_region
WITH item_freight AS (
  SELECT c.region AS customer_region, oi.price, oi.freight_value,
         CASE WHEN p.weight_g IS NULL  THEN '5. unknown'
              WHEN p.weight_g <  500   THEN '1. < 0.5 kg'
              WHEN p.weight_g < 2000   THEN '2. 0.5-2 kg'
              WHEN p.weight_g < 10000  THEN '3. 2-10 kg'
              ELSE                          '4. 10+ kg'
         END AS weight_band
  FROM order_items AS oi
  INNER JOIN orders    AS o ON o.order_id    = oi.order_id
  INNER JOIN customers AS c ON c.customer_id = o.customer_id
  INNER JOIN products  AS p ON p.product_id  = oi.product_id
  WHERE o.order_status NOT IN ('canceled', 'unavailable')
    AND o.purchase_ts >= @ws AND o.purchase_ts < @we_excl
)
SELECT CASE WHEN GROUPING(customer_region) = 1 THEN 'ALL REGIONS' ELSE customer_region END AS customer_region,
       CASE WHEN GROUPING(weight_band) = 1     THEN 'ALL WEIGHTS' ELSE weight_band END     AS weight_band,
       COUNT(*)                                                        AS items,
       ROUND(AVG(freight_value), 2)                                    AS avg_freight_brl,
       ROUND(100 * SUM(freight_value) / SUM(price + freight_value), 1) AS freight_share_of_gmv_pct
FROM item_freight
GROUP BY customer_region, weight_band WITH ROLLUP   -- adds per-region subtotals + a grand total
ORDER BY GROUPING(customer_region), customer_region, GROUPING(weight_band), weight_band;
-- Reading the result: WITH ROLLUP adds a subtotal per region and a grand total (111,752 items, R$19.99
--   average freight, 14.2% of GMV). North customers pay R$36.87 per item (18.5% of GMV) and Northeast R$32.22
--   (17.9%) vs R$17.37 (13.2%) in the Southeast.
