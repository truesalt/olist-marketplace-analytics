/* ============================================================================
   File        : a08_items_vs_payments_reconciliation.sql
   Purpose     : Order-by-order reconciliation of what was billed (items + freight) against
                 what was paid, across ALL orders - including orders that exist on only one side.
   Business Q  : Do item totals match what customers paid?
   SQL concepts: FULL OUTER JOIN emulation (LEFT JOIN ... UNION ALL ... RIGHT JOIN WHERE left
                 key IS NULL), pre-aggregated CTEs, CASE classification with a R$0.01 tolerance,
                 ABS, conditional aggregation, LIMIT
   Output      : reconciliation_summary, reconciliation_examples
   Run with    : mysql --local-infile=1 -u $MYSQL_USER -p olist \
                   < sql/analysis/a08_items_vs_payments_reconciliation.sql
   ========================================================================== */

-- @query: reconciliation_summary
WITH items_by_order AS (
  SELECT order_id, SUM(price + freight_value) AS items_total
  FROM order_items
  GROUP BY order_id
),
payments_by_order AS (
  SELECT order_id, SUM(payment_value) AS paid_total
  FROM order_payments
  GROUP BY order_id
),
full_outer AS (                    -- MySQL has no FULL OUTER JOIN:
  SELECT i.order_id, i.items_total, p.paid_total          -- (1) every order with items (+ payments if any)
  FROM items_by_order AS i
  LEFT JOIN payments_by_order AS p ON p.order_id = i.order_id
  UNION ALL
  SELECT p.order_id, NULL AS items_total, p.paid_total    -- (2) orders with payments but NO items
  FROM items_by_order AS i
  RIGHT JOIN payments_by_order AS p ON p.order_id = i.order_id
  WHERE i.order_id IS NULL         -- keeps only the right-side rows (1) missed -> no duplicates
),
classified AS (
  SELECT fo.order_id, fo.items_total, fo.paid_total,
         CASE
           WHEN fo.paid_total  IS NULL                       THEN '4. items only (no payment)'
           WHEN fo.items_total IS NULL                       THEN '5. payments only (no items)'
           WHEN ABS(fo.paid_total - fo.items_total) <= 0.01  THEN '1. match (within R$0.01)'
           WHEN fo.paid_total > fo.items_total               THEN '2. overpaid (paid > billed)'
           ELSE                                                   '3. underpaid (paid < billed)'
         END AS reconciliation_status
  FROM full_outer AS fo
)
SELECT reconciliation_status,
       COUNT(*)                                                  AS orders,
       ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)          AS pct_of_orders,
       ROUND(SUM(COALESCE(items_total, 0)), 2)                   AS items_total_brl,
       ROUND(SUM(COALESCE(paid_total, 0)), 2)                    AS paid_total_brl,
       ROUND(SUM(COALESCE(paid_total, 0) - COALESCE(items_total, 0)), 2) AS net_difference_brl
FROM classified
GROUP BY reconciliation_status
ORDER BY reconciliation_status;
-- Reading the result: 98,362 orders (98.92%) match to the cent. 264 are overpaid (+R$3,070.14 in total; card
--   instalment interest is the usual reason), 39 underpaid (-R$199.08), 1 order has items but no payment, and
--   772 orders have payments but no items (R$162,591.95 paid, all outside the GMV base).

-- @query: reconciliation_examples
WITH items_by_order AS (
  SELECT order_id, SUM(price + freight_value) AS items_total
  FROM order_items
  GROUP BY order_id
),
payments_by_order AS (
  SELECT order_id, SUM(payment_value) AS paid_total, COUNT(*) AS n_payments,
         MAX(payment_installments) AS max_installments
  FROM order_payments
  GROUP BY order_id
),
full_outer AS (
  SELECT i.order_id, i.items_total, p.paid_total, p.n_payments, p.max_installments
  FROM items_by_order AS i
  LEFT JOIN payments_by_order AS p ON p.order_id = i.order_id
  UNION ALL
  SELECT p.order_id, NULL, p.paid_total, p.n_payments, p.max_installments
  FROM items_by_order AS i
  RIGHT JOIN payments_by_order AS p ON p.order_id = i.order_id
  WHERE i.order_id IS NULL
)
SELECT fo.order_id,
       o.order_status,
       ROUND(fo.items_total, 2)                                        AS items_total_brl,
       ROUND(fo.paid_total, 2)                                         AS paid_total_brl,
       ROUND(COALESCE(fo.paid_total, 0) - COALESCE(fo.items_total, 0), 2) AS difference_brl,
       fo.n_payments,
       fo.max_installments
FROM full_outer AS fo
INNER JOIN orders AS o ON o.order_id = fo.order_id
WHERE fo.items_total IS NULL
   OR fo.paid_total IS NULL
   OR ABS(fo.paid_total - fo.items_total) > 0.01
ORDER BY ABS(COALESCE(fo.paid_total, 0) - COALESCE(fo.items_total, 0)) DESC, fo.order_id
LIMIT 20;
-- Reading the result: the 20 largest gaps are all payments-only orders in status unavailable or canceled
--   (top: R$3,782.19 paid, no items recorded). This is a refund-tracking question, not a GMV leak.
