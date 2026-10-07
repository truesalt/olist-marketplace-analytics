# Interview prep

All numbers come from `results/` (file in brackets). Learn the **why** behind each, not just the number.

## 60-second pitch

> "Olist is a Brazilian marketplace. I asked which delivery failures, discount practices and seller-supply gaps cost it
> five-star reviews, repeat customers and GMV.
> **Data:** the public Olist datasets, 1.56 million raw rows across 11 files, covering about 99,000 orders and a
> seller-acquisition funnel.
> **Method:** a MySQL 8 pipeline. Raw staging, then a typed core with constraints, loaded in one transaction with 17 logged
> cleaning rules and a 33-check audit. On top of that, a star schema, 20 analysis modules, hypothesis tests in Python and a
> Power BI kit.
> **Three findings:** first, a late delivery makes a 1-2 star review 6.8 times more likely, 62.5% vs 9.2%. Second, the promise
> breaks on long lanes: ten lanes hold 70% of late orders, and North customers wait a median 20 days vs 9. Third, growth is
> acquisition-only: just 2% of customers come back within 180 days, and 18% of sellers make 80% of GMV.
> **Recommendation:** fix the ten worst lanes and run a seller-quality programme first, which avoids about 1,700 bad reviews a year.
> Test a second-order voucher before rolling it out, because the observational voucher effect isn't significant."

(1,369 + 321 = 1,690 ≈ 1,700, from `results/stats/impact_sizing.csv`.)

## Resume bullets

1. **Built an end-to-end MySQL 8.4 analytics pipeline** (staging → constrained core → star schema; 20 analysis modules,
   43 result sets) on 99k orders / 1.56M raw rows, with a transaction-safe load, 17 logged cleaning rules and a 33-check
   quality audit. Showed late deliveries raise the 1-2★ review rate from **9.2% to 62.5%** (two-proportion z-test,
   **p < 0.0001**; relative risk 6.8).
2. **Diagnosed delivery-SLA failure by lane** using window functions (medians, DENSE_RANK, gaps-and-islands). The 10 worst
   seller→customer lanes hold **70% of late orders**, and North customers wait a median **20 vs 9 days** (bootstrap 95% CI
   +11 to +12 days) while paying **18.5% of GMV in freight vs 13.2%**. Sized fixes worth **≈ 1,690 fewer low reviews a year**.
3. **Designed retention and supply analytics plus a powered A/B test** (cohorts, RFM, Pareto, seller funnel; 21,174
   users/arm for a +20% MDE). Found 180-day repeat of just **1.99%**, **18.4% of sellers driving 80% of GMV**, and that
   social-sourced sellers yield **R$ 30 vs R$ 87** of 90-day GMV per lead. Delivered a Power BI star-schema kit with 29 DAX measures.

## 25 likely questions, with model answers

**1. What is the grain trap in this dataset?**
`customer_id` is created per order, so one person can have up to 17 customer_ids
(`07_data_quality_audit__data_quality_report.csv`). Counting repeat customers on `customer_id` gives roughly zero repeaters by
construction. Every customer-level metric (repeat, cohorts, RFM) uses `customer_unique_id`.

**2. What is the fan-out problem and how big was it here?**
Joining two one-to-many tables on the same key multiplies rows: 2 items × 3 payments = 6 rows. Items ⋈ payments
turned 97,905 orders into 116,664 rows, overstating GMV by 4.56% and payments by 28.06% (a07). Fix: aggregate each side
to one row per order, then join 1:1.

**3. MySQL has no FULL OUTER JOIN. What did you do?**
`LEFT JOIN` (all left rows) `UNION ALL` a `RIGHT JOIN … WHERE left.key IS NULL` (only the right-only rows). UNION ALL is
safe because the two halves can't overlap, and it is cheaper than UNION's de-duplication (a08).

**4. How do you compute a median in MySQL?**
`ROW_NUMBER()` and `COUNT(*) OVER (PARTITION BY group)`, then average the rows at positions FLOOR((n+1)/2) and
CEIL((n+1)/2). That's one row when n is odd and two when it's even. For percentiles, take the first value with `CUME_DIST() ≥ p` (a04, a12).

**5. Why a staging layer instead of loading straight into typed tables?**
A typed load fails, or silently coerces, on the first dirty value. Staging is all text with no keys, so the bulk load never
fails. Cleaning then happens in SQL where every rule is explicit, logged in `dq_log` and repeatable.

**6. How is the load transaction-safe?**
`sp_load_core()` wraps everything in `START TRANSACTION … COMMIT` with an EXIT HANDLER that runs `ROLLBACK; RESIGNAL`.
It uses `DELETE`, not `TRUNCATE`, because TRUNCATE is DDL and commits implicitly. I proved it by planting an invalid status:
the CHECK constraint fired mid-load and core still held the previous full load (`06_…__rollback_test.csv`).

**7. Did indexes speed up your queries?**
Not the big ones. a04 and a11 read about 95% of orders, so a full scan is already optimal (1,187 → 1,107 ms, same rows
examined). Selective look-ups improved 18-144×, e.g. one customer's history went from 99,478 to 52 rows examined (docs/performance.md).
The heavy aggregations are solved by marts instead.

**8. What is SARGability?**
Whether a predicate can use an index seek. `YEAR(purchase_ts) = 2018` wraps the column in a function, so every index entry
must be evaluated. `purchase_ts >= '2018-01-01' AND purchase_ts < '2019-01-01'` can seek. For one month the range form was
13× faster (24.8 → 1.9 ms).

**9. Explain your recursive CTE.**
Anchor = first date; recursive member = previous date + 1 day; stop condition in WHERE. It replaces `generate_series`.
I use it to zero-fill: a LEFT JOIN from the spine turns missing days into 0 instead of dropping them. In the North,
dropping zero days overstates average daily orders by 13% (a03).

**10. How does gaps-and-islands work?**
For a seller's active months, `month_idx − ROW_NUMBER()` is constant within a run of consecutive months and jumps after a
gap, so GROUP BY that difference gives each streak. In MySQL ROW_NUMBER is unsigned, so cast it to SIGNED (a14).

**11. What is right-censoring and how did you handle it?**
A customer who first bought in July 2018 has only weeks to come back, so including them drags the repeat rate down.
"Repeat-eligible" means the first order is ≤ window_end − 180 days, so everyone in the denominator had the full 180 days.
Cohort cells after the window end are NULL, not 0.

**12. Why a z-test and not a t-test?**
The outcomes are binary (low review yes/no, repeat yes/no), so I compare two proportions. With large n the sampling
distribution of the difference is normal, so the two-proportion z-test applies. A t-test compares means of continuous
variables.

**13. Chi-square vs z-test?**
The z-test compares two groups on one binary outcome (late vs on time → low review). Chi-square tests whether a whole
table is independent: 5 delay buckets × 5 scores. χ² = 19,619, Cramér's V = 0.228 (T2). With n = 94k everything is
"significant", so I report effect sizes.

**14. Late first orders repeat less. Is that causal?**
Not proven. 1.58% vs 2.02% is not significant (p = 0.057, CI −0.81 to +0.02 pp, T3), and late orders differ in region
and category. The logistic regression (T5) holds voucher use, order value, region and category fixed: OR 0.79 (CI 0.61-1.02,
p = 0.071), the same direction and still not significant. The base rate is about 2%, so the data lacks power.

**15. Why did you leave review score out of the regression?**
It is a **mediator**: late delivery → bad review → no return. Controlling for it would block part of the very effect I
want to measure and bias the late coefficient toward zero.

**16. Voucher users repeat more. Should Olist give everyone vouchers?**
No. 2.50% vs 1.97% is not significant (p = 0.0705), and voucher users self-select (deal-seekers, prior relationships).
That's why I designed an A/B test: baseline 1.99%, MDE +20% relative, α 0.05, power 0.8 → 21,174 per arm, ≈ 29 weeks to
enrol plus 26 weeks follow-up. Guardrails: AOV, margin proxy, low-review %, cancellations (T7).

**17. Why that MDE, and what if the test is too long?**
+20% relative (+0.40 pp) is about the smallest lift that could pay for a voucher. If 55 weeks is too long, I'd accept a
larger MDE, use 90-day repeat as a proxy, or run the test only in high-volume regions.

**18. Describe your Power BI model.**
A star schema: one fact at order-item grain, four dimensions, many-to-one single-direction relationships. Order-level fields
are denormalised onto items so order measures use DISTINCTCOUNT(order_id). Lead and mart tables stand alone because they
have different grains, and connecting them would create ambiguous paths.

**19. Why is Avg Delivery Days order-weighted?**
An order with 5 items would count 5 times in a plain AVERAGE over the item-grain fact. AVERAGEX over
VALUES(order_id) with CALCULATE(MAX(delivery_days)) gives one value per order.

**20. DIVIDE vs "/" in DAX?**
`DIVIDE(a, b)` returns BLANK (or an alternate result) when b is 0 or BLANK. `/` returns an error or infinity, which breaks
visuals and totals.

**21. MySQL has no materialized views. What did you do?**
Summary tables `mart_*` rebuilt by `sp_refresh_marts()` (TRUNCATE + INSERT … SELECT) with a `mart_refresh_log` row per
mart. A gate check proves the monthly mart reconciles to the fact view to the cent: R$ 15,683,706.74.

**22. Which data-quality decision are you least sure about?**
Excluding 1,382 timestamp-anomaly orders (1.39%) from SLA metrics. Most have a carrier hand-off recorded before payment
approval, which may be a recording quirk rather than a real problem. They stay in GMV and counts; only delivery-time
statistics drop them. I flagged it as a WARN rather than hiding it.

**23. Tell me about a bug you found in your own pipeline.**
Pandas quoted every English category name in a result CSV, which was odd. Two source files used Windows `\r\n` line endings
that macOS `file` didn't flag, so each category carried an invisible `\r`. I fixed the loader (`LINES TERMINATED BY '\r\n'`),
added an audit check for control characters, and now count carriage returns per file instead of trusting `file`.

**24. What is the biggest limitation?**
No cost or margin data and no clickstream. I can size impact in reviews and GMV but not profit or conversion. Repeat purchase is
also so rare that customer-level effects are under-powered. Everything is observational except the proposed tests.

**25. How does this apply to Meesho / Flipkart, or to a consulting client?**
Meesho/Flipkart: the same lane-SLA and promise-accuracy logic drives **RTO** (return-to-origin) and COD refusals. A
late or over-promised delivery gets refused at the door. I'd add RTO as an outcome next to reviews and model the promise per
pincode-pair. Consulting client (ZS, EXL, Fractal): the reusable pieces are the staging → audit → star schema pattern, the
fan-out and reconciliation checks, cohort and eligibility rules, and translating effects into sized, testable
recommendations.

## "Explain this query in 60 seconds" cards

### a04 · Delivery SLA by lane
1. Join orders → customers → items → sellers; keep valid deliveries in the window.
2. `SELECT DISTINCT order_id, seller_state, customer_state, …` so a 3-item order counts once per lane.
3. Window functions per lane: `ROW_NUMBER()` and `COUNT(*) OVER` → median from the middle row(s).
4. `GROUP BY lane HAVING COUNT(*) >= @min_lane` (100, from cfg) to drop noisy lanes.
5. `DENSE_RANK()` by late orders (where the pain is) and by late % (where the process breaks).
**Result:** SP→SP has the most late orders (1,424 at 4.70%); SP→AL has the worst rate (23.62%).

### a07 · Fan-out trap
1. Naive CTE: items ⋈ payments on order_id, then SUM price and payment → 116,664 rows for 97,905 orders.
2. Correct: items per order and payments per order in two CTEs, joined 1:1.
3. Compare: GMV +4.56%, payments +28.06% overstated by the naive join.
**Rule:** bring every side to the join grain before joining.

### a08 · Reconciliation (FULL OUTER JOIN)
1. CTEs: items total per order, payments total per order.
2. LEFT JOIN (orders with items) UNION ALL RIGHT JOIN … WHERE items side IS NULL (orders with only payments).
3. CASE: match within R$ 0.01 / overpaid / underpaid / items-only / payments-only.
**Result:** 98.92% match; 772 payments-only orders are canceled/unavailable orders outside GMV.

### a11 · Cohort retention
1. Distinct (person, month) pairs from valid orders.
2. Cohort = MIN(month) per person; months_since = PERIOD_DIFF(month, cohort).
3. CASE pivot: COUNT(DISTINCT person) for months_since = 0..6 ÷ cohort size.
4. NULL when the month is after the window end (not observable), not 0.
**Result:** month-1 retention 0.22-0.71%, so the business runs on new customers.

### a12 · Repeat and time to second order
1. ROW_NUMBER over (person, purchase_ts) → first order and its attributes (late? voucher? value? category?).
2. LEAD over **distinct purchase days** → next later-day purchase (same-day checkouts aren't returns).
3. Eligibility: first order ≤ window_end − 180 days (no right-censoring).
4. Split repeat rate by first-order late/on-time and voucher/no voucher; percentiles via CUME_DIST.
**Result:** 1.58% vs 2.02% (late vs on time), median 105 days to return; exported per-customer rows feed T3-T5.

### a14 · Seller gaps and islands
1. Active months per seller as an integer index (PERIOD_DIFF from window start).
2. island_key = month_idx − ROW_NUMBER() (cast SIGNED): constant inside consecutive months.
3. GROUP BY island → start, end, length; LEAD(start) → gap after each island.
4. Gap ≥ 2 months = churn episode; monthly churn via NOT EXISTS look-ahead for m and m+1.
**Result:** 58.5% of sellers had a churn episode; 13-23% of active sellers go silent each month.
