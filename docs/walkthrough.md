# Walkthrough: every analysis query in plain language

For each module: **what it answers**, **the logic step by step**, **the trickiest line and why**, and **how to explain
it in 60 seconds**. Numbers come from `results/sql/<file>__<query>.csv`.

---

### a01 · Executive KPIs
* **Answers:** how big and healthy the marketplace is. R$ 15.68M GMV, 97,905 orders, 94,703 customers,
  AOV R$ 160.19, 93.14% on time, 13.84% low reviews, but only 1.99% of eligible customers re-order within 180 days.
* **Logic:** filter valid orders (status + window) → sum items per order → one row of order-level totals → separate
  one-row CTEs for sellers, reviews, repeat → `CROSS JOIN` the one-row CTEs.
* **Trickiest line:** `INNER JOIN order_items` inside `item_totals`. It silently defines "valid orders have ≥ 1 item",
  which keeps SQL and Power BI order counts identical.
* **60 s:** "One query, one row: each KPI comes from its own CTE at the right grain, then I cross-join single-row CTEs.
  NULLIF guards every division."

### a02 · Monthly trends
* **Answers:** GMV rose 8.6× from Jan-2017 to the Nov-2017 Black Friday peak (R$ 1.17M), then plateaued; YoY growth
  fell from +704.65% to +50.62%.
* **Logic:** recursive month spine → monthly GMV → LEFT JOIN spine to sales (zero-fill) → LAG(1), LAG(12),
  3-month moving average, running total over a named window.
* **Trickiest line:** `LAG(gmv, 12)` is only "same month last year" because the spine guarantees consecutive
  months. Without it, a missing month would shift every comparison.
* **60 s:** "Generate the calendar first, then attach data, so gaps become zeros instead of disappearing. Then window
  functions give MoM, YoY, smoothing and cumulative revenue in one pass."

### a03 · Daily spine by region
* **Answers:** true average daily orders. The North has 70 zero-order days in 608, and a naive average overstates it
  by 13.01% (3.40 vs 3.01 orders/day).
* **Logic:** recursive day spine × `CROSS JOIN` regions → LEFT JOIN daily orders → COALESCE to 0 → compare AVG over
  all days vs AVG over days with orders → 7-day moving average per region.
* **Trickiest line:** `AVG(CASE WHEN orders > 0 THEN orders END)`. This reproduces the wrong (naive) average on
  purpose, to quantify the bias.
* **60 s:** "GROUP BY only returns days that exist. For sparse segments that inflates averages, so I build the full
  day × region grid first."

### a04 · Delivery SLA by lane
* **Answers:** SP→SP has the most late orders (1,424; 4.70%), SP→RJ is #2 (1,149; 14.22%). The worst rates are SP→AL
  (23.62%), MA→SP (21.19%) and SP→MA (19.62%). The 10 worst lanes hold 4,286 of 6,107 late orders.
* **Logic:** four-table join to (order, seller state, customer state) → DISTINCT so items don't double count →
  ROW_NUMBER + COUNT per lane for the median → GROUP BY lane HAVING ≥ 100 → DENSE_RANK by late orders. The second
  query pivots regions into columns with CASE.
* **Trickiest line:** `AVG(CASE WHEN rn IN (FLOOR((n+1)/2), CEIL((n+1)/2)) THEN delivery_days END)`, the median
  without PERCENTILE_CONT (odd n → one row, even n → mean of two).
* **60 s:** "Lane = seller state to customer state. I rank by late *count* (where the pain is) and late *rate*
  (where the process is broken). Volume lanes and long-haul lanes need different fixes."

### a05 · Delay vs review
* **Answers:** the share of 1-2 star reviews goes from 9.0% (7+ days early) and 10.8% (on time) to 32.3%, 67.7% and
  79.3% as delays grow; the average score falls 4.31 → 1.70.
* **Logic:** valid orders with a review → `fn_delay_bucket(delay_days)` → GROUP BY bucket → CASE pivot of the 5 scores.
* **Trickiest line:** `ORDER BY delay_bucket`. The labels carry numeric prefixes ("1." … "5.") so text sort = delay order.
* **60 s:** "A dose-response table: the later the parcel, the worse the review, with no exceptions. T1/T2 confirm it
  statistically."

### a06 · Worst sellers per category
* **Answers:** 257 of 624 qualifying seller-category pairs are above their category's late rate. They cause 47.8% of
  late seller deliveries, and 1,006 of those are *excess* late orders.
* **Logic:** (order, seller, category) rows → category late % → seller late % (HAVING ≥ 30) → keep sellers whose rate
  beats a **correlated subquery** on their own category → DENSE_RANK per category → keep ranks ≤ 3.
* **Trickiest line:** `WHERE ss.seller_late_pct > (SELECT cs.category_late_pct FROM category_stats cs WHERE
  cs.category_en = ss.category_en)`. The subquery re-runs per seller with that seller's category.
* **60 s:** "A furniture seller shouldn't be compared with a phone-case seller. Each seller is judged against its own
  category, and I filter the window result in an outer CTE because MySQL has no QUALIFY."

### a07 · Fan-out trap
* **Answers:** joining items to payments turns 97,905 orders into 116,664 rows and overstates GMV by 4.56% and payments by
  28.06%.
* **Logic:** naive join vs. aggregating each side per order first, then joining 1:1.
* **Trickiest line:** `SUM(op.payment_value)` in the naive CTE. Each payment is repeated once per item, which is why
  payments inflate more than GMV.
* **60 s:** "Two one-to-many tables joined on the same key multiply. Always bring every side to the join grain before
  joining."

### a08 · Items vs payments reconciliation
* **Answers:** 98.92% of orders match to the cent; 264 overpaid (+R$ 3,070, instalment interest), 39 underpaid,
  1 items-only, 772 payments-only (canceled/unavailable orders with no items).
* **Logic:** items per order and payments per order → FULL OUTER JOIN emulation → CASE classification with R$ 0.01
  tolerance.
* **Trickiest line:** `RIGHT JOIN … WHERE i.order_id IS NULL`. The second half adds only the rows the LEFT JOIN
  missed, so nothing is duplicated (UNION ALL is safe and faster than UNION).
* **60 s:** "Finance-style tie-out: every order lands in exactly one bucket, and the two orphan buckets only exist
  because of the full outer join."

### a09 · Anti- and semi-joins
* **Answers:** 636 valid deliveries (0.67%) have no review; 1,232 sellers went silent for the last 90 days of the
  window; 55,363 customers (57.61%) left a 5-star review.
* **Logic:** each question written two ways (NOT EXISTS vs LEFT JOIN IS NULL; EXISTS vs IN) with identical counts.
  Silent sellers use a correlated scalar subquery for each seller's last sale.
* **Trickiest line:** `DATEDIFF(data_end_ts, last_sale_ts) > 90`, where `data_end_ts` is an uncorrelated scalar
  subquery: the last purchase in the window, not today's date.
* **60 s:** "Anti-join = rows with no partner, semi-join = rows with at least one partner. EXISTS stops at the first
  match, so it never duplicates rows the way a plain JOIN can."

### a10 · Set operations
* **Answers:** 42,370 of 43,034 people who bought in 2017 did not buy again in 2018 (to Aug); 505 sellers were active
  in both H1-2017 (970) and H1-2018 (1,994); UNION vs UNION ALL differ by exactly the 664 people who bought in both
  years.
* **Logic:** distinct buyer/seller sets per period → EXCEPT / INTERSECT (native since 8.0.31) next to NOT EXISTS /
  INNER JOIN equivalents.
* **Trickiest line:** wrapping set operations in `SELECT COUNT(*) FROM ( … EXCEPT … ) AS x`. The derived table needs
  an alias in MySQL.
* **60 s:** "Set operators answer 'in A but not B' directly. I also show the join versions because older MySQL and
  some warehouses lack EXCEPT/INTERSECT."

### a11 · Cohort retention
* **Answers:** 0.22%-0.71% of a monthly cohort orders again in month 1; no later month exceeds 0.60%.
* **Logic:** distinct (person, month) pairs → cohort = MIN(month) → `PERIOD_DIFF` month offset → CASE pivot M0-M6 →
  NULL where the month is after the window end.
* **Trickiest line:** `CASE WHEN PERIOD_DIFF(@we_ym, cohort_ym) >= k THEN … END`. It separates "0 customers came back"
  from "we cannot see that month yet" (right-censoring).
* **60 s:** "Group customers by first-purchase month and track them like a class through time. Here the class
  practically never comes back, so this is an acquisition-driven business."

### a12 · Repeat and time to second order
* **Answers:** eligible returners take a median 105 days (p25 34, p75 202) to come back. Repeat is 1.58% after a late
  first order vs 2.02% on time, and 2.50% with a voucher vs 1.97% without. Neither gap is significant (T3, T4).
* **Logic:** ROW_NUMBER picks the first order → LEAD over *distinct purchase days* finds the next later day →
  eligibility = first order ≤ window_end − 180 → splits → percentiles via ROW_NUMBER/COUNT (median) and CUME_DIST
  (p25/p75) → customer-level export for Python.
* **Trickiest line:** `LEAD(purchase_date) OVER (PARTITION BY customer_unique_id ORDER BY purchase_date)` on
  `SELECT DISTINCT customer_unique_id, purchase_date`. Collapsing to days first means a same-day second checkout
  is not counted as a return.
* **60 s:** "Repeat needs two guards: count people (customer_unique_id), not order-level ids; and only judge
  customers we observed for the full 180 days."

### a13 · RFM segmentation
* **Answers:** only 3.03% of customers have 2+ orders. "At risk - high value" (22.17% of people) holds 40.06% of GMV;
  Champions are 1.29% of people and 2.52% of GMV.
* **Logic:** order values → R (days since last order), F (orders), M (GMV) → NTILE(5) for R and M, F as 1 vs 2+ →
  CASE segments. A second query shows first vs latest category with FIRST_VALUE / LAST_VALUE.
* **Trickiest line:** `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`. Without it, LAST_VALUE stops at the
  current row (default frame) and returns that row's own value.
* **60 s:** "Textbook RFM breaks when 97% buy once, because NTILE would split identical F values at random. So F
  becomes a flag, and value is driven by spend and recency."

### a14 · Seller gaps and islands
* **Answers:** sellers average 1.71 activity streaks of 3.12 months; 58.5% had a churn episode (≥ 2 silent months);
  13-23% of last month's active sellers go silent each month.
* **Logic:** month index per seller → `month_idx − ROW_NUMBER()` is constant within consecutive months (an island) →
  island bounds → LEAD to the next island = gap length → monthly churn via NOT EXISTS look-ahead.
* **Trickiest line:** `CAST(ROW_NUMBER() OVER (…) AS SIGNED)`. ROW_NUMBER is BIGINT UNSIGNED in MySQL, and the subtraction
  errors out when negative.
* **60 s:** "Consecutive months minus a running counter give the same number, so grouping by that difference finds
  every unbroken streak without loops."

### a15 · Order status funnel
* **Answers:** of 99,092 orders, 99.86% are approved, 98.25% reach a carrier, 97.07% are delivered, 96.42% reviewed.
  The 12.58-day average splits into 0.39 days approval, 2.80 days seller handling and 9.35 days transit.
* **Logic:** cumulative stage flags per order → sums → unpivot with UNION ALL → FIRST_VALUE / LAG for % of start and
  step conversion → TIMESTAMPDIFF hours per stage with a window median.
* **Trickiest line:** `24 * DATEDIFF(review_created_date, DATE(delivered_ts))`. The review date has no time, so a
  timestamp difference would go negative; days are the honest unit.
* **60 s:** "A funnel is cumulative flags plus conversion between steps. The duration split shows transit is
  three-quarters of lead time, but seller handling is the part Olist controls."

### a16 · Seller acquisition funnel
* **Answers:** 8,000 MQLs → 842 signed (10.53%) → 379 sold (45.0% of signed) → 182 active 3 of 6 months (2.28%).
  First-90-day GMV per signed seller: unknown R$ 935.50, organic R$ 736.06, paid R$ 704.93, social R$ 536.98.
* **Logic:** LEFT JOIN chain lead → first sale → active months (a missing stage keeps the lead row) → GROUP BY origin
  → median days to close → GROUP_CONCAT of top landing pages.
* **Trickiest line:** `LEFT JOIN first_sale AS fs ON fs.seller_id = l.seller_id`. Unwon leads have NULL seller_id
  and fall through as "no sale" instead of disappearing.
* **60 s:** "Marketing usually stops at 'won'. I follow the seller to its first sale and three active months, which
  changes the channel ranking: social signs few sellers and they sell less."

### a17 · Pareto concentration
* **Answers:** the top 1% of sellers (31) make 25.73% of GMV, top 20% make 81.86%, and 556 sellers (18.36%) make 80%.
  The top 7 categories make 49.88%.
* **Logic:** seller GMV → running SUM over GMV desc ÷ total = cumulative share → PERCENT_RANK for tiers → CROSS JOIN
  with a tiers table and conditional sums.
* **Trickiest line:** `SUM(gmv) OVER (ORDER BY gmv DESC, seller_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`.
  The tie-breaker and ROWS frame make the running total deterministic.
* **60 s:** "Cumulative share answers 'how few sellers carry the business?' Here it's a fifth of them, so seller
  retention matters as much as customer retention."

### a18 · Categories and strings
* **Answers:** health_beauty (R$ 1.43M), watches_gifts and bed_bath_table (most orders: 9,394) lead. Capitals dominate
  their states (São Paulo 37.2% of SP orders). Cleaning merges 2,076 raw spellings in the geolocation table.
* **Logic:** translation LEFT JOIN + COALESCE fallback → label clean-up (REPLACE/UPPER/SUBSTRING) → top-3 cities
  per state with ROW_NUMBER → distinct counts under binary vs accent-insensitive collation.
* **Trickiest line:** `COUNT(DISTINCT city COLLATE utf8mb4_bin)`. Under the default `_ai_ci` collation, 'São Paulo'
  and 'sao paulo' are already one value, so raw variants are only visible with a binary collation.
* **60 s:** "String cleaning is measurable: collation alone merges 8,010 spellings to 5,969, and the accent function
  to 5,934."

### a19 · Basket self-join
* **Answers:** only 783 of 97,905 orders (0.80%) span two categories. Just 5 pairs reach 20 orders and only
  bed_bath_table + home_confort has lift > 1 (1.13).
* **Logic:** distinct (order, category) → self-join on order_id with `a.category_en < b.category_en` → support,
  confidence, lift.
* **Trickiest line:** `a.category_en < b.category_en`. `<` (not `<>`) keeps each unordered pair once and removes
  self-pairs.
* **60 s:** "Lift compares co-occurrence with what independence predicts. With single-category baskets dominating,
  cross-sell is not a lever here, which is itself a useful negative result."

### a20 · Freight economics
* **Answers:** freight is 11.8% of item price under 100 km but 22.6% beyond 1,500 km, where delivery takes 20.5 vs 6.5
  days and is late 11.6% vs 4.5%. North customers pay R$ 36.87 per item (18.5% of GMV) vs R$ 17.37 (13.2%) in the
  Southeast.
* **Logic:** `ST_Distance_Sphere` seller↔customer distance → CASE bands → ratios vs a scalar-subquery overall
  average → category view → region × weight band `WITH ROLLUP` subtotals labelled via GROUPING().
* **Trickiest line:** `GROUP BY customer_region, weight_band WITH ROLLUP` plus `GROUPING()`. ROLLUP adds subtotal rows
  whose NULLs must be labelled, not confused with real NULLs.
* **60 s:** "Distance raises cost and delay together. Remote customers pay more for a worse service, which is why the
  lane and promise fixes matter most for the North and Northeast."
