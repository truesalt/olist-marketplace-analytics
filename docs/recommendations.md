# Recommendations

**Stakeholder:** Head of Marketplace Operations & Growth, Olist.
**Question:** which delivery failures, discount practices and seller-supply gaps are costing 5-star reviews, repeat
customers and GMV, and what should be fixed first?

Every number below comes from `results/`. The impact estimates are computed in
[`notebooks/01_statistical_tests.ipynb`](../notebooks/01_statistical_tests.ipynb) → [`results/stats/impact_sizing.csv`](../results/stats/impact_sizing.csv)
with the formula shown. They are **planning estimates** with stated assumptions, not forecasts. The data window is
20 months (Jan-2017 to Aug-2018), and "per year" means × 12/20.

**The core mechanism.** A late delivery multiplies the chance of a 1-2 star review by 6.8: 62.48% vs 9.24% low reviews,
a +53.24 pp gap (95% CI +52.03 to +54.44 pp, T1). Late first orders also look less likely to come back
(1.58% vs 2.02%), but that gap is **not statistically significant** (p = 0.057, T3; OR 0.79, CI 0.61-1.02, T5). So the
reliable lever is **review quality and trust**, not short-term repeat GMV.

## Priority order

| # | Recommendation | Main KPI | Estimated impact / year | Confidence |
|---|---|---|---|---|
| 1 | Fix the 10 lanes with the most late orders | On-time %, low-review % | ≈ 1,369 fewer low reviews | High (T1 effect is large and precise) |
| 2 | Seller quality programme for sellers above their category's late rate | Seller late %, low-review % | ≈ 321 fewer low reviews | High |
| 3 | Re-calibrate the promised date on chronically late lanes (A/B test) | Low-review %, conversion (guardrail) | up to ≈ 734 fewer low reviews | Medium (conversion trade-off unknown) |
| 4 | Shift seller-acquisition effort from social to search channels | GMV-90d per MQL | ≈ R$ 56,850 first-90-day GMV per 1,000 MQLs moved | Medium (no CAC data) |
| 5 | Test a second-order voucher before rolling it out | 180-day repeat rate | ≈ 308 extra repeat customers ≈ R$ 49,417 GMV, *if* +20% lift | Low (observational gap not significant) |

---

## 1. Fix the worst lanes first

* **Finding.** 70 lanes (seller state → customer state) have ≥ 100 deliveries. The 10 with the most late orders hold
  **4,286 late orders, 70.2% of all late orders on those lanes**. They are dominated by São Paulo sellers: SP→SP 1,424
  late (4.70%), SP→RJ 1,149 (14.22%), SP→MG 393, SP→BA 293 (12.84%) …
  (`results/sql/a04_delivery_sla_by_lane__lane_sla_state.csv`). Northeast-bound deliveries are late 12.2-13.0% of the time
  from the Southeast, South and Center-West vs 6.4% within the Southeast (`…__lane_sla_region_matrix.csv`).
* **Action.** Lane-by-lane carrier review for these 10 lanes: compare carriers on the same lane, add a second carrier
  where one dominates, enforce seller cut-off times (seller handling averages 2.80 days, a15), and evaluate a forward
  stock point for RJ and the Northeast.
* **Owner.** Head of Logistics / carrier management.
* **Estimated impact.**
  * Low reviews avoided ≈ late orders on the 10 lanes × low-review gap (late − on time) × 12/20
    = 4,286 × 53.24 pp × 0.6 ≈ **1,369 per year**.
  * Repeat GMV ≈ 4,286 × 0.44 pp (T3 gap) × AOV R$ 160.19 × 0.6 ≈ **R$ 1,814 per year**. This is negligible and the gap
    itself is not significant, so do **not** sell this as a revenue project. Sell it as protecting ratings, which drive
    search ranking and conversion.
  * Assumptions: fixed lanes deliver on time; the low-review gap is causal (supported by the dose-response in T2).
* **How to validate.** Weekly on-time % per lane from `mart_lane_sla`, with treated lanes vs comparable untreated lanes
  (difference-in-differences). Secondary: low-review % on treated lanes.

## 2. Seller quality programme (sellers above their category's late rate)

* **Finding.** Of 624 seller-category pairs with ≥ 30 deliveries, **257 are later than their own category's average**.
  They produce 3,120 of 6,533 late seller deliveries (47.8%), of which **1,006 are "excess"** late orders beyond what
  their category's rate predicts (`results/sql/a06_worst_sellers_per_category__sellers_above_category_avg_count.csv`).
  The 3 worst per category are listed in `…__worst_sellers_top3.csv`.
* **Action.** Monthly SLA scorecard per seller (`CALL sp_seller_scorecard(seller_id)`), then warning → coaching on
  handling time → reduced search visibility for persistent offenders. Pair it with "ship by" reminders on the
  shipping-limit date.
* **Owner.** Seller Success / Marketplace Quality.
* **Estimated impact.** Bring flagged sellers to their category average → 1,006 fewer late orders per 20 months
  → low reviews avoided ≈ 1,006 × 53.24 pp × 0.6 ≈ **321 per year**.
* **How to validate.** Staggered rollout: randomly assign half of the flagged sellers to start first. Compare their
  late % and low-review % against the not-yet-enrolled half for 8 weeks.

## 3. Re-calibrate promised delivery dates on chronically late lanes

* **Finding.** 13 qualifying lanes are late **≥ 12%** of the time. They account for 2,299 late orders, and when late they
  arrive **12.4 days** after the promise on average (order-weighted; `impact_sizing.csv`, from a04). A review is driven
  by the gap between promise and reality (a05: early or on time ≈ 9-11% low reviews).
* **Action.** Set the promise per lane from its own delivery-time distribution (e.g. the 80th percentile of
  `delivery_days` on the lane) instead of one national rule.
* **Owner.** Product (checkout / delivery promise) with Logistics analytics.
* **Estimated impact.** If a realistic promise turned those late arrivals into on-time arrivals:
  2,299 × 53.24 pp × 0.6 ≈ **up to 734 fewer low reviews per year**. Risk: a longer promise can lower conversion.
* **How to validate.** A/B test on promise padding, randomised by customer on the 13 lanes. Primary metric: low-review %
  and on-time-vs-promise %. **Guardrails:** checkout conversion (needs clickstream), cancellations, AOV.

## 4. Shift seller-acquisition effort toward search channels

* **Finding.** First-90-day GMV generated **per MQL** (MQL→won % × GMV-90d per won seller): organic_search
  **R$ 86.86**, paid_search **R$ 86.71**, direct_traffic R$ 46.67, social **R$ 29.86**
  (`results/stats/impact_sizing.csv`; inputs `a16_seller_acquisition_funnel__lead_funnel_by_origin.csv` and
  `…__won_seller_value_by_origin.csv`). Social converts 5.56% of leads (vs 12.30% paid search) and takes a median 30
  days to close. Overall only 2.28% of MQLs become sellers active in 3 of their first 6 months.
* **Action.** Re-allocate SDR time and budget from social to paid and organic search; tighten social lead
  qualification. Separately, fix the post-signing leak: 55% of signed sellers never sell (onboarding programme).
* **Owner.** Seller acquisition (Marketing + SDR/SR leads).
* **Estimated impact.** Per 1,000 MQLs moved from social to paid search: 1,000 × (R$ 86.71 − R$ 29.86) ≈
  **R$ 56,850 more GMV in the sellers' first 90 days**. Cost side unknown (no CAC in the data).
* **How to validate.** Track GMV-90d per MQL by channel monthly. Run a budget-shift test (time-split or region-split)
  and add CAC to compute ROI per channel.

## 5. Test a second-order voucher, do not roll it out blind

* **Finding.** Customers who paid their first order with a voucher repeated 2.50% vs 1.97%, but the difference is
  **not significant** (+0.54 pp, 95% CI −0.04 to +1.26 pp, p = 0.0705, T4), and voucher users self-select. Baseline 180-day
  repeat is **1.99%** (a01).
* **Action.** Run the A/B test designed in T7. Randomise new customers at first delivery into control vs "voucher for
  the next order", with **21,174 customers per arm** (MDE +20% relative = +0.40 pp, α 0.05, power 0.8). At 6,459 new
  customers a month (2018 average) that is ≈ 29 weeks of enrolment plus 26 weeks to observe the 180-day outcome. Use 90-day
  repeat as an early read.
* **Owner.** CRM / Growth.
* **Estimated impact (if the MDE is achieved).** 6,459 × 12 × 0.40 pp ≈ **308 extra repeat customers per year** ×
  AOV R$ 160.19 ≈ **R$ 49,417 GMV per year**, *before* voucher cost. It only pays if voucher cost per redemption is below the margin
  on the extra order.
* **How to validate.** The test itself. Guardrails: AOV of the second order, margin proxy (voucher cost / GMV), low-review %,
  cancellation rate.

---

## What I would do with more data

| Data | Why it matters |
|---|---|
| **Margin / commission per order** | Turn GMV into contribution, so every recommendation gets a profit number, and the voucher test a break-even. |
| **Marketing cost per lead (CAC)** | ROI per acquisition channel; recommendation 4 currently compares output only. |
| **Clickstream / sessions** | Conversion for the promise A/B test (rec. 3), plus sessionisation (same LAG + running-SUM pattern as a14). |
| **Carrier id per shipment** | Separate carrier performance from lane difficulty (rec. 1). |
| **Refund / cancellation reasons** | Explain the 772 payments-only orders (a08) and late-driven cancellations. |
| **Review text (Portuguese NLP)** | Separate "late" complaints from product-quality complaints in the 1-2 star reviews. |
