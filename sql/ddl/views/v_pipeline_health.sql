-- v_pipeline_health — single-glance view of warehouse freshness.
--
-- For the LLM and for humans: "is the data I'm about to query current,
-- or is the sync broken?". Surfaces the latest Shopify `updated_at` and
-- `created_at` per storefront, the latest FX snapshot, the latest
-- product-catalog refresh, a per-region inter-table-consistency flag
-- (orders vs refunds vs fulfilments), and a cross-warehouse overall_status.
--
-- Thresholds are deliberately generous so a one-off slow day doesn't
-- trip a false "stale". Alarms on actually-broken pipelines should come
-- from CloudWatch on the Lambda's Errors metric (see INFRA.md), not from
-- anyone polling this view.
--
-- LLM behaviour: check overall_status first. If != 'fresh', preface any
-- revenue/volume answer with a caveat and name the stale region(s).

CREATE OR REPLACE VIEW `peppermayo.v_pipeline_health`
(
  store_region OPTIONS(description="Storefront region: AU, US, UK, CA, EU."),
  total_orders OPTIONS(description="Row count in orders_master for this region."),
  last_order_created_at OPTIONS(description="Most recent order created_at (UTC) in this region."),
  last_order_updated_at OPTIONS(description="Most recent order updated_at (UTC) in this region. Drives the freshness calculation."),
  hours_since_last_order_update OPTIONS(description="Hours between CURRENT_TIMESTAMP() and last_order_updated_at."),
  orders_freshness OPTIONS(description="'fresh' (<=30h) / 'stale' (<=48h) / 'broken' (>48h). CHECK THIS before answering any 'today' or 'yesterday' revenue question."),
  total_refunds OPTIONS(description="Row count in refunds_master for this region."),
  last_refund_updated_at OPTIONS(description="Most recent refund updated_at (UTC)."),
  total_fulfillments OPTIONS(description="Row count in fulfillments_master for this region."),
  last_fulfillment_updated_at OPTIONS(description="Most recent fulfilment updated_at (UTC)."),
  is_refunds_in_sync OPTIONS(description="TRUE when last_refund_updated_at is within 2h of last_order_updated_at. FALSE indicates a merge-window skew — during 16:00–16:15 UTC net_revenue numbers may over-state slightly."),
  is_fulfillments_in_sync OPTIONS(description="TRUE when last_fulfillment_updated_at is within 2h of last_order_updated_at."),
  total_products OPTIONS(description="Row count in products_master for this region."),
  last_product_refresh_at OPTIONS(description="UTC timestamp of the most recent weekly product refresh."),
  days_since_last_product_refresh OPTIONS(description="Days between CURRENT_TIMESTAMP() and last_product_refresh_at."),
  products_freshness OPTIONS(description="'fresh' (<=8d) / 'stale' (<=15d) / 'broken' (>15d) / 'never'."),
  last_fx_date OPTIONS(description="Most recent DATE in fx_rates_master (all regions share this)."),
  total_fx_rows OPTIONS(description="Row count in fx_rates_master."),
  days_since_last_fx OPTIONS(description="Days between CURRENT_DATE() and last_fx_date. >4 days typically indicates broken FX sync (ECB gaps are usually 3 days at most over long weekends)."),
  fx_coverage_ok OPTIONS(description="TRUE when zero orders in the last 24h have NULL *_aud columns (i.e. FX is covering every currency × date touched by fresh orders). FALSE means currency conversion is silently dropping orders from AUD/USD aggregates."),
  null_fx_orders_24h OPTIONS(description="Count of orders created in the last 24h where fx_native_to_aud IS NULL (would cause SUM(total_price_aud) to silently under-report)."),
  last_customers_refresh_at OPTIONS(description="UTC timestamp of the most recent customers_master refresh (daily)."),
  total_customers OPTIONS(description="Row count in customers_master."),
  overall_status OPTIONS(description="Worst-case status across all regions and FX. 'fresh' only when every region is fresh, FX is fresh, and fx_coverage_ok. Otherwise 'degraded' or 'broken'. THE LLM SHOULD CHECK THIS FIRST."),
  observed_at OPTIONS(description="Timestamp the view was evaluated.")
)
OPTIONS(description="Single-glance warehouse freshness. One row per storefront region. Check overall_status before trusting any revenue/volume answer.")
AS
WITH order_health AS (
  SELECT
    store_region,
    MAX(updated_at) AS last_order_updated_at,
    MAX(created_at) AS last_order_created_at,
    COUNT(*)        AS total_orders
  FROM `peppermayo.orders_master`
  GROUP BY store_region
),
refund_health AS (
  SELECT
    store_region,
    MAX(updated_at) AS last_refund_updated_at,
    COUNT(*)        AS total_refunds
  FROM `peppermayo.refunds_master`
  GROUP BY store_region
),
fulfillment_health AS (
  SELECT
    store_region,
    MAX(updated_at) AS last_fulfillment_updated_at,
    COUNT(*)        AS total_fulfillments
  FROM `peppermayo.fulfillments_master`
  GROUP BY store_region
),
fx_health AS (
  SELECT MAX(rate_date) AS last_fx_date, COUNT(*) AS total_fx_rows
  FROM `peppermayo.fx_rates_master`
),
fx_coverage AS (
  -- Orders created in the last 24h whose native-to-AUD rate is NULL.
  -- Non-zero here means currency conversion is silently dropping rows
  -- from SUM(*_aud) aggregates.
  SELECT COUNTIF(fx.rate_to_aud IS NULL) AS null_fx_orders_24h
  FROM `peppermayo.orders_master` o
  LEFT JOIN `peppermayo.v_fx_rates_filled` fx
    ON fx.currency = o.currency
   AND fx.rate_date = DATE(o.created_at)
  WHERE o.created_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)
),
product_health AS (
  SELECT
    store_region,
    MAX(refreshed_at) AS last_product_refresh_at,
    COUNT(*)          AS total_products
  FROM `peppermayo.products_master`
  GROUP BY store_region
),
customer_health AS (
  SELECT MAX(refreshed_at) AS last_customers_refresh_at, COUNT(*) AS total_customers
  FROM `peppermayo.customers_master`
),
per_region AS (
  SELECT
    o.store_region,
    o.total_orders,
    o.last_order_created_at,
    o.last_order_updated_at,
    TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), o.last_order_updated_at, HOUR) AS hours_since_last_order_update,
    CASE
      WHEN TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), o.last_order_updated_at, HOUR) <=  30 THEN 'fresh'
      WHEN TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), o.last_order_updated_at, HOUR) <=  48 THEN 'stale'
      ELSE 'broken'
    END AS orders_freshness,
    r.total_refunds,
    r.last_refund_updated_at,
    f.total_fulfillments,
    f.last_fulfillment_updated_at,
    -- Inter-table consistency. During 16:00–16:15 UTC the refunds/
    -- fulfilments merges run after the orders merge, so a brief window
    -- where orders are ahead is normal. We use 2h as a generous
    -- "same merge cycle" threshold.
    CASE
      WHEN r.last_refund_updated_at IS NULL THEN NULL
      ELSE ABS(TIMESTAMP_DIFF(o.last_order_updated_at, r.last_refund_updated_at, HOUR)) <= 2
    END AS is_refunds_in_sync,
    CASE
      WHEN f.last_fulfillment_updated_at IS NULL THEN NULL
      ELSE ABS(TIMESTAMP_DIFF(o.last_order_updated_at, f.last_fulfillment_updated_at, HOUR)) <= 2
    END AS is_fulfillments_in_sync,
    p.total_products,
    p.last_product_refresh_at,
    TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), p.last_product_refresh_at, DAY) AS days_since_last_product_refresh,
    CASE
      WHEN p.last_product_refresh_at IS NULL                                                     THEN 'never'
      WHEN TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), p.last_product_refresh_at, DAY) <=   8            THEN 'fresh'
      WHEN TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), p.last_product_refresh_at, DAY) <=  15            THEN 'stale'
      ELSE 'broken'
    END AS products_freshness
  FROM order_health o
  LEFT JOIN refund_health      r USING (store_region)
  LEFT JOIN fulfillment_health f USING (store_region)
  LEFT JOIN product_health     p USING (store_region)
),
globals AS (
  SELECT
    (SELECT last_fx_date               FROM fx_health)        AS last_fx_date,
    (SELECT total_fx_rows              FROM fx_health)        AS total_fx_rows,
    DATE_DIFF(CURRENT_DATE(), (SELECT last_fx_date FROM fx_health), DAY) AS days_since_last_fx,
    (SELECT null_fx_orders_24h         FROM fx_coverage)      AS null_fx_orders_24h,
    (SELECT null_fx_orders_24h = 0     FROM fx_coverage)      AS fx_coverage_ok,
    (SELECT last_customers_refresh_at  FROM customer_health)  AS last_customers_refresh_at,
    (SELECT total_customers            FROM customer_health)  AS total_customers,
    -- Worst-case over all regions.
    (SELECT MAX(orders_freshness = 'broken')                FROM per_region) AS any_region_broken,
    (SELECT MAX(orders_freshness = 'stale')                 FROM per_region) AS any_region_stale
)
SELECT
  pr.store_region,
  pr.total_orders,
  pr.last_order_created_at,
  pr.last_order_updated_at,
  pr.hours_since_last_order_update,
  pr.orders_freshness,
  pr.total_refunds,
  pr.last_refund_updated_at,
  pr.total_fulfillments,
  pr.last_fulfillment_updated_at,
  pr.is_refunds_in_sync,
  pr.is_fulfillments_in_sync,
  pr.total_products,
  pr.last_product_refresh_at,
  pr.days_since_last_product_refresh,
  pr.products_freshness,
  g.last_fx_date,
  g.total_fx_rows,
  g.days_since_last_fx,
  g.fx_coverage_ok,
  g.null_fx_orders_24h,
  g.last_customers_refresh_at,
  g.total_customers,
  CASE
    WHEN g.any_region_broken OR g.days_since_last_fx > 4 OR NOT g.fx_coverage_ok THEN 'broken'
    WHEN g.any_region_stale  OR g.days_since_last_fx > 2                         THEN 'degraded'
    ELSE 'fresh'
  END AS overall_status,
  CURRENT_TIMESTAMP() AS observed_at
FROM per_region pr
CROSS JOIN globals g
ORDER BY pr.store_region;
