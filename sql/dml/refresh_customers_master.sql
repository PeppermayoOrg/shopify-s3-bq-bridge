-- Refresh customers_master.
--
-- One row per customer_id, aggregated from v_orders (so every
-- monetary field is already AUD-normalised and cancellations are
-- available as a boolean). Refreshed daily by a BigQuery Scheduled
-- Query at ~16:15 UTC, after merge_orders.sql and merge_items.sql
-- have finished.
--
-- Guest checkouts (customer_id IS NULL) are excluded. Guest-order
-- "identity" is only recoverable via hashed_email, which has its
-- own limitations — add a second flavour of this table keyed on
-- hashed_email later if needed.
--
-- Revenue convention (stable across the warehouse):
--    lifetime_revenue_aud       = SUM(total_price_aud)         (GROSS, pre-refund)
--    lifetime_net_revenue_aud   = SUM(current_total_price_aud) (NET, Shopify's post-refund — CANONICAL)
--    lifetime_revenue_by_region = per-region gross revenue array
--
-- Rebuilding the whole table daily is cheap at Peppermayo's current
-- volume (tens of MB of orders_master). If this ever becomes
-- expensive, convert to an incremental MERGE keyed on customer_id.

CREATE OR REPLACE TABLE `peppermayo.customers_master` (
  customer_id STRING NOT NULL OPTIONS(description="Shopify customer ID. Primary key."),
  first_order_at TIMESTAMP OPTIONS(description="UTC timestamp of the customer's first non-cancelled order."),
  last_order_at TIMESTAMP OPTIONS(description="UTC timestamp of the customer's most recent non-cancelled order."),
  first_order_region STRING OPTIONS(description="Storefront region of the first order. Best available 'acquisition region' signal."),
  last_order_region STRING OPTIONS(description="Storefront region of the most recent order. May differ from first_order_region if the customer bought in a different market later."),
  regions_purchased_in ARRAY<STRING> OPTIONS(description="Distinct set of storefront regions the customer has ordered from, sorted. Use `'UK' IN UNNEST(regions_purchased_in)` to ask 'has this customer ever ordered in UK'."),
  has_multi_region_purchases BOOL OPTIONS(description="TRUE if regions_purchased_in contains more than one region."),
  first_discount_code STRING OPTIONS(description="First discount code applied on the customer's first order, or NULL. Useful for acquisition attribution."),
  lifetime_orders INT64 NOT NULL OPTIONS(description="Count of non-cancelled orders the customer has placed."),
  lifetime_cancelled_orders INT64 NOT NULL OPTIONS(description="Count of orders that were later cancelled."),
  lifetime_units_ordered INT64 NOT NULL OPTIONS(description="SUM of quantity across non-cancelled, non-gift-card line items. PRE-refund (units ordered)."),
  lifetime_units_refunded INT64 NOT NULL OPTIONS(description="SUM of quantity_refunded across non-cancelled, non-gift-card line items. Units returned via Shopify refunds."),
  lifetime_units INT64 NOT NULL OPTIONS(description="SUM of quantity_net = lifetime_units_ordered - lifetime_units_refunded (floored per line). CANONICAL units sold."),
  lifetime_return_rate FLOAT64 OPTIONS(description="lifetime_units_refunded / lifetime_units_ordered. NULL when lifetime_units_ordered = 0. Use for 'customers who have returned >N% of their items' segmentation."),
  lifetime_revenue_aud FLOAT64 NOT NULL OPTIONS(description="SUM(total_price_aud) across non-cancelled orders. GROSS (pre-refund)."),
  lifetime_revenue_usd FLOAT64 NOT NULL OPTIONS(description="SUM(total_price_usd) across non-cancelled orders. GROSS (pre-refund)."),
  lifetime_net_revenue_aud FLOAT64 NOT NULL OPTIONS(description="SUM(current_total_price_aud) across non-cancelled orders. CANONICAL net revenue — Shopify's post-refund figure, reconciles with Shopify reports."),
  lifetime_net_revenue_usd FLOAT64 NOT NULL OPTIONS(description="SUM(current_total_price_usd) across non-cancelled orders. CANONICAL net revenue in USD."),
  lifetime_discount_aud FLOAT64 NOT NULL OPTIONS(description="SUM of total_discounts_aud across non-cancelled orders."),
  lifetime_revenue_by_region ARRAY<STRUCT<region STRING, gross_revenue_aud FLOAT64, gross_revenue_usd FLOAT64, net_revenue_aud FLOAT64, net_revenue_usd FLOAT64, orders INT64>> OPTIONS(description="Per-region breakdown of the customer's lifetime. Use UNNEST to attribute revenue to a specific storefront. For 'top UK customers by LTV in USD' either (a) filter `'UK' IN UNNEST(regions_purchased_in)` and sort by lifetime_revenue_usd (whole-customer LTV) or (b) UNNEST this array, filter region='UK', and sort by its net_revenue_usd (UK-only LTV). Pick the interpretation that matches the question."),
  avg_order_value_aud FLOAT64 OPTIONS(description="lifetime_revenue_aud / lifetime_orders. NULL when lifetime_orders = 0."),
  days_since_last_order INT64 OPTIONS(description="CURRENT_DATE() - DATE(last_order_at). Useful for churn / reactivation segments."),
  is_repeat_customer BOOL NOT NULL OPTIONS(description="TRUE when lifetime_orders >= 2. LIFETIME flag. For 'repeat customer rate in month M' use v_orders.is_returning_customer_order instead."),
  is_churned BOOL NOT NULL OPTIONS(description="TRUE when days_since_last_order > 180. SNAPSHOT at refresh time. For 'customer came back after churning' use v_orders.is_reactivation_order instead."),
  refreshed_at TIMESTAMP NOT NULL OPTIONS(description="UTC timestamp this row was (re)computed.")
)
CLUSTER BY first_order_region
OPTIONS(
  description="Per-customer lifetime aggregates: LTV (gross and net), order counts, acquisition region, per-region revenue breakdown, return rate, recency. Rebuilt daily from v_orders. Excludes guest checkouts."
)
AS
WITH base AS (
  SELECT * FROM `peppermayo.v_orders` WHERE customer_id IS NOT NULL
),
per_order AS (
  SELECT
    *,
    ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY created_at ASC)  AS rn_first,
    ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY created_at DESC) AS rn_last
  FROM base
),
item_units AS (
  SELECT
    o.customer_id,
    SUM(IF(i.gift_card, 0, i.quantity))            AS lifetime_units_ordered,
    SUM(IF(i.gift_card, 0, i.quantity_refunded))   AS lifetime_units_refunded,
    SUM(IF(i.gift_card, 0, i.quantity_net))        AS lifetime_units
  FROM `peppermayo.v_order_items` i
  JOIN base o USING (order_id)
  WHERE NOT o.is_cancelled
  GROUP BY o.customer_id
),
per_region AS (
  SELECT
    customer_id,
    ARRAY_AGG(
      STRUCT(
        store_region              AS region,
        gross_revenue_aud         AS gross_revenue_aud,
        gross_revenue_usd         AS gross_revenue_usd,
        net_revenue_aud           AS net_revenue_aud,
        net_revenue_usd           AS net_revenue_usd,
        orders                    AS orders
      )
      ORDER BY store_region
    ) AS lifetime_revenue_by_region
  FROM (
    SELECT
      customer_id,
      store_region,
      SUM(total_price_aud)          AS gross_revenue_aud,
      SUM(total_price_usd)          AS gross_revenue_usd,
      SUM(current_total_price_aud)  AS net_revenue_aud,
      SUM(current_total_price_usd)  AS net_revenue_usd,
      COUNT(*)                      AS orders
    FROM base
    WHERE NOT is_cancelled
    GROUP BY customer_id, store_region
  )
  GROUP BY customer_id
),
aggregated AS (
  SELECT
    customer_id,
    MIN(IF(NOT is_cancelled, created_at, NULL)) AS first_order_at,
    MAX(IF(NOT is_cancelled, created_at, NULL)) AS last_order_at,
    ANY_VALUE(IF(rn_first = 1, store_region, NULL)) AS first_order_region,
    ANY_VALUE(IF(rn_last  = 1, store_region, NULL)) AS last_order_region,
    ARRAY_AGG(DISTINCT store_region IGNORE NULLS ORDER BY store_region) AS regions_purchased_in,
    ANY_VALUE(IF(rn_first = 1 AND ARRAY_LENGTH(discount_codes_array) > 0,
                 discount_codes_array[OFFSET(0)], NULL)) AS first_discount_code,
    COUNTIF(NOT is_cancelled) AS lifetime_orders,
    COUNTIF(is_cancelled)     AS lifetime_cancelled_orders,
    COALESCE(SUM(IF(NOT is_cancelled, total_price_aud, 0)), 0)          AS lifetime_revenue_aud,
    COALESCE(SUM(IF(NOT is_cancelled, total_price_usd, 0)), 0)          AS lifetime_revenue_usd,
    COALESCE(SUM(IF(NOT is_cancelled, current_total_price_aud, 0)), 0)  AS lifetime_net_revenue_aud,
    COALESCE(SUM(IF(NOT is_cancelled, current_total_price_usd, 0)), 0)  AS lifetime_net_revenue_usd,
    COALESCE(SUM(IF(NOT is_cancelled, total_discounts_aud, 0)), 0)      AS lifetime_discount_aud
  FROM per_order
  GROUP BY customer_id
)
SELECT
  a.customer_id,
  a.first_order_at,
  a.last_order_at,
  a.first_order_region,
  a.last_order_region,
  a.regions_purchased_in,
  ARRAY_LENGTH(a.regions_purchased_in) > 1 AS has_multi_region_purchases,
  a.first_discount_code,
  a.lifetime_orders,
  a.lifetime_cancelled_orders,
  COALESCE(iu.lifetime_units_ordered,  0) AS lifetime_units_ordered,
  COALESCE(iu.lifetime_units_refunded, 0) AS lifetime_units_refunded,
  COALESCE(iu.lifetime_units,          0) AS lifetime_units,
  SAFE_DIVIDE(iu.lifetime_units_refunded, iu.lifetime_units_ordered) AS lifetime_return_rate,
  a.lifetime_revenue_aud,
  a.lifetime_revenue_usd,
  a.lifetime_net_revenue_aud,
  a.lifetime_net_revenue_usd,
  a.lifetime_discount_aud,
  COALESCE(pr.lifetime_revenue_by_region, []) AS lifetime_revenue_by_region,
  SAFE_DIVIDE(a.lifetime_revenue_aud, a.lifetime_orders) AS avg_order_value_aud,
  DATE_DIFF(CURRENT_DATE(), DATE(a.last_order_at), DAY) AS days_since_last_order,
  a.lifetime_orders >= 2 AS is_repeat_customer,
  COALESCE(DATE_DIFF(CURRENT_DATE(), DATE(a.last_order_at), DAY) > 180, FALSE) AS is_churned,
  CURRENT_TIMESTAMP() AS refreshed_at
FROM aggregated a
LEFT JOIN item_units iu USING (customer_id)
LEFT JOIN per_region pr USING (customer_id);
