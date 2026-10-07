# Metric definitions

The table below is the contract from `PROJECT_SPEC.md` §7, reproduced verbatim. Every SQL file, view, mart, DAX measure and
chart uses these definitions. The implementation notes after it record the exact choices made where the
one-line definition leaves room for interpretation.

| Metric | Definition |
|---|---|
| Valid order | order_status NOT IN ('canceled','unavailable') and purchase_ts within window |
| GMV | SUM(price + freight_value) over items of valid orders (BRL; keep BRL, label "R$") |
| Merchandise value | SUM(price) |
| Orders | COUNT(DISTINCT order_id) of valid orders |
| AOV | GMV / Orders |
| Items per order | COUNT(items) / Orders |
| Freight share | SUM(freight) / GMV |
| Valid delivery | is_valid_delivery = 1 (delivered, has date, no anomaly) |
| Delivery days | DATEDIFF(delivered date, purchase date) |
| Delay days | DATEDIFF(delivered date, estimated date); > 0 = late |
| Late order | delay_days > 0 |
| On-time % | 1 − late orders / valid deliveries |
| Low review | review_score ≤ 2 |
| Low-review % | low-review orders / orders with a review |
| Customer | customer_unique_id |
| New customer (month) | customer whose first valid order is in that month |
| Repeat (180d) | customer with a second valid order within 180 days after first order |
| Repeat-eligible | first order on/before window_end − 180 days (avoids right-censoring bias) |
| Voucher first order | first order has ≥1 payment row with payment_type = 'voucher' |
| Active seller (month) | ≥1 item sold in that month |
| Seller churn episode | gap of ≥ 2 consecutive inactive months after being active |
| Lead conversion % | won leads / MQLs |
| Days to close | won_date − first_contact_date |
| Seller GMV 90d | GMV of seller's items in 90 days after first sale |
| MoM % / YoY % | (this − previous) / previous; YoY only where prior-year month exists |

## Parameters (table `cfg_params`, read with `fn_cfg()`)

| Parameter | Value | Used for |
|---|---|---|
| window_start | 2017-01-01 | first purchase date in scope (the 2016 months are sparse) |
| window_end | 2018-08-31 | last purchase date in scope (later months hold only a few, mostly canceled orders) |
| repeat_horizon_days | 180 | repeat window |
| low_review_max | 2 | 1-2 stars = low |
| min_orders_seller | 30 | minimum valid deliveries for a seller (in a category) to be ranked |
| min_orders_lane | 100 | minimum valid deliveries for a lane to be ranked |

## Implementation notes

1. **Window bounds.** `purchase_ts >= window_start AND purchase_ts < window_end + 1 day`. The end date is inclusive,
   and the half-open interval keeps the predicate SARGable (see `docs/performance.md`).
2. **Valid order must have ≥ 1 item.** 5 in-window orders (status created/invoiced/shipped) have no items. They carry
   no GMV and cannot appear in the item-grain fact, so they are excluded everywhere. That way SQL and Power BI report the
   same 97,905 orders.
3. **Days are calendar days.** Delivery and delay days use `DATEDIFF` on dates, not timestamps. `estimated_date` has no time
   part, so a parcel delivered at 23:00 on the promised day counts as on time.
4. **Repeat (180d) = a valid order on a later calendar day.** Extra checkouts placed on the *same day* as the first
   order happen before the first parcel arrives, so they cannot be a reaction to the experience. Counting them would
   dilute every "does the first experience drive repeat?" comparison. Implemented with `LEAD()` over distinct purchase
   days (a12) and the same rule in `v_dim_customer`.
5. **First order** is the earliest valid order by `purchase_ts`, ties broken by `order_id`. Its customer address
   (state/region) is the customer's address in `dim_customer`.
6. **Lanes** are seller state → customer state. An order with sellers in two states counts once in each lane, while
   several items from the same seller state count once (`SELECT DISTINCT order_id, seller_state, …`).
7. **Late rate** uses valid deliveries only. `is_late` is NULL for anything else, so it can never inflate or
   deflate the rate.
8. **Percent conventions.** Analysis CSVs (`results/sql/*_pct`) hold **percentages 0-100**. Marts and Power BI
   exports (`mart_*`, `*_pct` columns there) hold **fractions 0-1** formatted as % in Power BI.
9. **Seller GMV 90d** covers the 90 days starting on the first-sale day (`sale_date < first_sale_date + 90`). Sellers
   who signed late in the window have less time, so it is a lower bound for them.
10. **Churn episode** (a14) counts both a gap the seller came back from and a trailing gap of ≥ 2 months at the end
    of the window. Monthly churn = sellers active in m−1 and silent in both m and m+1, divided by active sellers in m−1.
