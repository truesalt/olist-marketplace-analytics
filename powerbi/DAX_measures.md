# DAX measures

Create a measures table first: **Home → Enter data** → name it `_Measures` → Load (an empty
one-column table). Then select `_Measures` and use **New measure** for each block below. After
the first measure exists, delete the dummy `Column1`; the table then shows a calculator icon and
sorts to the top of the field list.

All column references are checked against the exported CSV headers by `python/export_powerbi.py`
(`make export` prints "DAX check: … 0 problems").

> Why `DIVIDE()` and not `/`: `DIVIDE(a, b)` returns BLANK instead of an error when `b` is 0 or
> BLANK, e.g. a month with no deliveries. Visuals then show an empty cell instead of `∞`/error.

## Core sales

| Measure | Meaning | Format |
|---|---|---|
| GMV | Gross merchandise value = item price + freight, valid orders only (R$) | `R$ #,##0` |
| Merchandise Value | Item prices only, without freight | `R$ #,##0` |
| Orders | Distinct valid orders. The fact is item-grain, so orders must be DISTINCTCOUNTed | `#,##0` |
| AOV | Average order value = GMV / Orders | `R$ #,##0.00` |
| Customers | Distinct people (customer_unique_id) who bought in the current filter context | `#,##0` |
| Active Sellers | Distinct sellers with ≥ 1 item sold in the filter context | `#,##0` |
| Freight Share | Freight as a share of GMV | `0.0%` |

```DAX
GMV = SUM ( fact_order_items[item_gmv] )
Merchandise Value = SUM ( fact_order_items[price] )
Orders = DISTINCTCOUNT ( fact_order_items[order_id] )
AOV = DIVIDE ( [GMV], [Orders] )
Customers = DISTINCTCOUNT ( fact_order_items[customer_unique_id] )
Active Sellers = DISTINCTCOUNT ( fact_order_items[seller_id] )
Freight Share = DIVIDE ( SUM ( fact_order_items[freight_value] ), [GMV] )
```

## Delivery

| Measure | Meaning | Format |
|---|---|---|
| Valid Deliveries | Orders delivered with a date and no timestamp anomaly | `#,##0` |
| Late Orders | Valid deliveries that arrived after the promised date | `#,##0` |
| On-time % | 1 − late / valid deliveries | `0.0%` |
| Avg Delivery Days | Average purchase→delivery days, **one value per order** (not per item) | `0.0` |

```DAX
Valid Deliveries =
CALCULATE ( [Orders], fact_order_items[is_valid_delivery] = 1 )
Late Orders =
CALCULATE ( [Orders], fact_order_items[is_valid_delivery] = 1, fact_order_items[is_late] = 1 )
On-time % = DIVIDE ( [Valid Deliveries] - [Late Orders], [Valid Deliveries] )

-- order-weighted (not item-weighted) average: one value per order
Avg Delivery Days =
AVERAGEX (
    CALCULATETABLE ( VALUES ( fact_order_items[order_id] ), fact_order_items[is_valid_delivery] = 1 ),
    CALCULATE ( MAX ( fact_order_items[delivery_days] ) )
)
```

> Why order-weighted: an order with 5 items would count 5 times in `AVERAGE(delivery_days)`. AVERAGEX
> iterates the distinct order_ids, and `CALCULATE(MAX(...))` (context transition) fetches that order's
> single delivery_days value.

## Reviews

| Measure | Meaning | Format |
|---|---|---|
| Reviewed Orders | Orders that received a review | `#,##0` |
| Low Review Orders | Orders scored 1–2 stars | `#,##0` |
| Low Review % | Low-review orders / reviewed orders | `0.0%` |

```DAX
Reviewed Orders =
CALCULATE ( [Orders], NOT ISBLANK ( fact_order_items[review_score] ) )
Low Review Orders =
CALCULATE ( [Orders], fact_order_items[is_low_review] = 1 )
Low Review % = DIVIDE ( [Low Review Orders], [Reviewed Orders] )
```

## Time intelligence (needs `dim_date` marked as date table)

| Measure | Meaning | Format |
|---|---|---|
| GMV PM | GMV of the previous month | `R$ #,##0` |
| GMV MoM % | Month-over-month growth | `0.0%` |
| GMV PY | GMV of the same period last year | `R$ #,##0` |
| GMV YoY % | Year-over-year growth, blank where no prior-year data | `0.0%` |
| GMV 3M Avg | Average monthly GMV over the 3 months ending at the current date | `R$ #,##0` |

```DAX
GMV PM = CALCULATE ( [GMV], DATEADD ( dim_date[date], -1, MONTH ) )
GMV MoM % = DIVIDE ( [GMV] - [GMV PM], [GMV PM] )
GMV PY = CALCULATE ( [GMV], SAMEPERIODLASTYEAR ( dim_date[date] ) )
GMV YoY % = IF ( NOT ISBLANK ( [GMV PY] ), DIVIDE ( [GMV] - [GMV PY], [GMV PY] ) )
GMV 3M Avg =
DIVIDE (
    CALCULATE ( [GMV], DATESINPERIOD ( dim_date[date], MAX ( dim_date[date] ), -3, MONTH ) ),
    3
)
```

## Customers (cohort-based, from `dim_customer`)

| Measure | Meaning | Format |
|---|---|---|
| Eligible Customers | People whose first order leaves a full 180-day observation window | `#,##0` |
| Repeat Customers 180d | Eligible people with a later-day valid order within 180 days | `#,##0` |
| Repeat Rate 180d | Repeat customers / eligible customers | `0.00%` |

```DAX
Eligible Customers =
CALCULATE ( COUNTROWS ( dim_customer ), dim_customer[eligible_repeat] = 1 )
Repeat Customers 180d =
CALCULATE ( COUNTROWS ( dim_customer ), dim_customer[eligible_repeat] = 1, dim_customer[repeat_180d] = 1 )
Repeat Rate 180d = DIVIDE ( [Repeat Customers 180d], [Eligible Customers] )
```

> `Customers` counts people who **bought in the current filter context** (fact-based). The repeat measures
> count rows of `dim_customer`, i.e. a **cohort** view: each person once, judged on their first order.
> A slicer on `dim_customer` (e.g. first_order_is_late) changes both; a date slicer on `dim_date` filters the fact only.

## Sellers: Top-N worst

`Top N` is a **What-if parameter**: Modeling → New parameter → Numeric range → Name `Top N`,
Data type Whole number, Minimum 5, Maximum 25, Increment 1, Default 10, ✔ Add slicer to this page.
Power BI creates the table `'Top N'` with column `[Top N]` and measure `[Top N Value]`.

| Measure | Meaning | Format |
|---|---|---|
| Seller Late Rank | Dense rank of sellers by late orders in the current selection (1 = most late orders) | `0` |
| Show In Top N | 1 if the seller is within the chosen Top N, else 0 (use as visual filter = 1) | `0` |

```DAX
Seller Late Rank =
RANKX ( ALLSELECTED ( dim_seller ), [Late Orders], , DESC, DENSE )
Show In Top N = IF ( [Seller Late Rank] <= 'Top N'[Top N Value], 1, 0 )
```

> Why `ALLSELECTED ( dim_seller )` and not `ALLSELECTED ( dim_seller[seller_id] )`: the Top-N table shows
> `dim_seller[seller_code]`. Ranking over the seller_id column alone leaves the row's seller_code filter in place,
> so every other seller evaluates to BLANK and every row ranks 1 (all 3,095 sellers pass `Show In Top N = 1`).
> Iterating the whole (3,095-row) table replaces the filters on all its columns, so the rank is correct whichever
> seller column the visual uses.

## Seller acquisition funnel (from `fact_seller_leads`)

| Measure | Meaning | Format |
|---|---|---|
| MQLs | Marketing-qualified leads | `#,##0` |
| Won Leads | Leads that signed (closed deal) | `#,##0` |
| Lead Conversion % | Won / MQLs | `0.0%` |
| Sellers With First Sale | Won leads whose seller made ≥ 1 valid sale | `#,##0` |
| GMV 90d per Won Seller | GMV in the first 90 days after first sale, averaged over **all** won leads (non-sellers count as 0) | `R$ #,##0` |

```DAX
MQLs = COUNTROWS ( fact_seller_leads )
Won Leads = CALCULATE ( COUNTROWS ( fact_seller_leads ), fact_seller_leads[is_won] = 1 )
Lead Conversion % = DIVIDE ( [Won Leads], [MQLs] )
Sellers With First Sale =
CALCULATE ( COUNTROWS ( fact_seller_leads ), fact_seller_leads[made_first_sale] = 1 )
GMV 90d per Won Seller =
DIVIDE ( SUM ( fact_seller_leads[gmv_first_90d] ), [Won Leads] )
```

## Expected values (whole model, no filters) - use them to validate the build

These must match the SQL results (sources in brackets):

| Measure | Expected | Source |
|---|---|---|
| GMV | R$ 15,683,707 | `results/sql/a01_executive_kpis__kpi_summary.csv` |
| Orders | 97,905 | a01 |
| AOV | R$ 160.19 | a01 |
| On-time % | 93.1% | a01 (93.14) |
| Avg Delivery Days | 12.5 | a01 (12.54) |
| Low Review % | 13.8% | a01 (13.84) |
| Repeat Rate 180d | 1.99% | a01 |
| MQLs / Won Leads / Sellers With First Sale | 8,000 / 842 / 379 | `a16_seller_acquisition_funnel__lead_funnel_overall.csv` |
