-- v_orders — canonical order view for BI and LLM querying.
--
-- Wraps orders_master with:
--    AUD and USD normalised monetary columns (suffixes _aud / _usd) so
--     cross-region questions work without mixing currencies.
--    ARRAY<STRING> versions of tags and discount_codes so the LLM can
--     UNNEST / filter on individual values.
--    A friendly source_name mapping.
--    Sydney-local date buckets for "today AEST" style queries.
--    Convenience booleans (is_cancelled, is_refunded_full,
--     is_returning_customer_order, is_reactivation_order).
--    Refund rollups and fulfilment rollups.
--
-- Revenue naming convention (stable across the warehouse):
--    gross_revenue_aud          = total_price_aud            (pre-refund, post-discount, incl. tax+shipping)
--    net_revenue_aud            = current_total_price_aud    (Shopify's post-refund figure; CANONICAL, reconciles with Shopify reports)
--    net_revenue_from_refunds_aud = total_price - SUM(refund_amount) at order-date FX
--       (diagnostic only — use when auditing refund flow vs Shopify's current_total_price)
--
-- Prefer this view over orders_master for any stakeholder-facing
-- question. The raw table is only appropriate when a column is
-- missing from the view.

CREATE OR REPLACE VIEW `peppermayo.v_orders`
(
  store_region OPTIONS(description="Storefront region: AU, US, UK, CA, EU."),
  order_id OPTIONS(description="Shopify order ID. Globally unique across stores. Primary key."),
  customer_id OPTIONS(description="Shopify customer ID. NULL for guest checkouts."),
  created_at OPTIONS(description="UTC timestamp the order was placed."),
  updated_at OPTIONS(description="UTC timestamp of the most recent Shopify-side mutation."),
  cancelled_at OPTIONS(description="UTC timestamp the order was cancelled, or NULL."),
  closed_at OPTIONS(description="UTC timestamp the order was archived/closed, or NULL."),
  created_date_utc OPTIONS(description="DATE of created_at in UTC."),
  created_date_sydney OPTIONS(description="DATE of created_at in Australia/Sydney. Prefer this for 'today'/'yesterday' questions. Partition pruning still applies."),
  created_month_sydney OPTIONS(description="Sydney-local month (first-of-month DATE) for monthly aggregation."),
  financial_status OPTIONS(description="Payment state: pending, authorized, paid, partially_paid, refunded, partially_refunded, voided."),
  fulfillment_status OPTIONS(description="Fulfilment state: fulfilled, partial, unfulfilled, restocked. Never NULL."),
  currency OPTIONS(description="ISO-4217 native currency code (AUD/USD/GBP/CAD/EUR). All un-suffixed *_price columns are in this currency."),
  presentment_currency OPTIONS(description="Currency the customer saw at checkout. Equal to `currency` for Peppermayo's single-currency storefronts."),
  subtotal_price OPTIONS(description="Line-items after per-line discounts, BEFORE order-level discounts/tax/shipping. NATIVE currency."),
  total_discounts OPTIONS(description="Total discount applied across the order. NATIVE currency."),
  total_tax OPTIONS(description="Total tax collected on the order. NATIVE currency."),
  total_shipping_price OPTIONS(description="Total shipping charged. NATIVE currency."),
  total_price OPTIONS(description="Grand total at checkout (incl. tax+shipping, net of discounts). NATIVE currency. Pre-refund."),
  current_total_price OPTIONS(description="Grand total AFTER post-order refunds. NATIVE currency. This is Shopify's canonical net-revenue figure."),
  subtotal_price_aud OPTIONS(description="subtotal_price converted to AUD at order-date FX."),
  total_discounts_aud OPTIONS(description="total_discounts converted to AUD at order-date FX."),
  total_tax_aud OPTIONS(description="total_tax converted to AUD at order-date FX."),
  total_shipping_price_aud OPTIONS(description="total_shipping_price converted to AUD at order-date FX."),
  total_price_aud OPTIONS(description="GROSS revenue in AUD (pre-refund, post-discount, incl. tax+shipping). Also exposed as gross_revenue_aud."),
  current_total_price_aud OPTIONS(description="NET revenue in AUD (Shopify's post-refund figure). Also exposed as net_revenue_aud. CANONICAL for cross-region totals."),
  subtotal_price_usd OPTIONS(description="subtotal_price converted to USD via AUD."),
  total_discounts_usd OPTIONS(description="total_discounts converted to USD via AUD."),
  total_tax_usd OPTIONS(description="total_tax converted to USD via AUD."),
  total_shipping_price_usd OPTIONS(description="total_shipping_price converted to USD via AUD."),
  total_price_usd OPTIONS(description="GROSS revenue in USD. Also exposed as gross_revenue_usd."),
  current_total_price_usd OPTIONS(description="NET revenue in USD (Shopify's post-refund). Also exposed as net_revenue_usd. CANONICAL."),
  gross_revenue_aud OPTIONS(description="Alias of total_price_aud. Pre-refund, post-discount gross revenue in AUD."),
  gross_revenue_usd OPTIONS(description="Alias of total_price_usd. Pre-refund gross revenue in USD."),
  net_revenue_aud OPTIONS(description="CANONICAL net revenue in AUD. Equal to current_total_price_aud (Shopify's post-refund total). Reconciles with Shopify reports."),
  net_revenue_usd OPTIONS(description="CANONICAL net revenue in USD. Equal to current_total_price_usd."),
  tags_array OPTIONS(description="ARRAY<STRING> of Shopify order tags. Use with UNNEST(). Empty array if no tags."),
  discount_codes_array OPTIONS(description="ARRAY<STRING> of discount codes. Trimmed (no leading/trailing whitespace). Use with UNNEST()."),
  tags OPTIONS(description="Raw comma-separated tag string. Prefer tags_array."),
  discount_codes OPTIONS(description="Raw comma-separated discount codes. Prefer discount_codes_array."),
  source_name_friendly OPTIONS(description="Human-readable channel: Online Store / Point of Sale / Manual-Draft / Shopify Mobile / Third-party App / Unknown."),
  source_name OPTIONS(description="Raw Shopify channel identifier. Prefer source_name_friendly."),
  order_number OPTIONS(description="Customer-visible order number; not globally unique (scope by store_region)."),
  cancel_reason OPTIONS(description="Reason code when cancelled: customer, fraud, inventory, declined, other. NULL otherwise."),
  payment_gateway OPTIONS(description="Payment gateway, e.g. shopify_payments, paypal, afterpay."),
  device_type OPTIONS(description="Inferred device class at checkout: desktop, mobile, tablet, or empty."),
  referring_site OPTIONS(description="HTTP referer at checkout. Free text; empty if direct."),
  shipping_city OPTIONS(description="Shipping address city."),
  shipping_province OPTIONS(description="Shipping address state/province."),
  shipping_country_code OPTIONS(description="ISO 3166-1 alpha-2 shipping country. For 'orders shipping to X' questions use this, NOT store_region."),
  total_weight_grams OPTIONS(description="Total parcel weight in grams."),
  hashed_email OPTIONS(description="SHA-256 of lower-cased trimmed email. The only way to group guest orders by person."),
  is_cancelled OPTIONS(description="TRUE when cancelled_at IS NOT NULL. v_orders does NOT pre-filter cancelled orders — add WHERE NOT is_cancelled."),
  is_refunded_full OPTIONS(description="TRUE when financial_status IN ('refunded','voided')."),
  is_refunded_partial OPTIONS(description="TRUE when financial_status = 'partially_refunded'."),
  is_unfulfilled OPTIONS(description="TRUE when fulfillment_status = 'unfulfilled'."),
  is_returning_customer_order OPTIONS(description="TRUE when this is NOT the customer's first non-cancelled order (order rank > 1 per customer). NULL for guest checkouts. Use this for 'repeat customer rate in month M' style questions — do NOT use customers_master.is_repeat_customer, which is a lifetime flag."),
  previous_order_at OPTIONS(description="UTC timestamp of the customer's previous non-cancelled order, or NULL if this is their first. NULL for guests."),
  days_since_previous_order OPTIONS(description="Days between previous_order_at and created_at. NULL for first orders and guests."),
  is_reactivation_order OPTIONS(description="TRUE when days_since_previous_order > 180. Use this for 'customer came back after churning' / 'which codes win back churned customers' questions — do NOT use customers_master.is_churned, which is a snapshot at refresh time."),
  refund_count OPTIONS(description="Number of refund events against this order (0 if none)."),
  first_refund_at OPTIONS(description="UTC timestamp of the earliest refund on this order, or NULL."),
  last_refund_at OPTIONS(description="UTC timestamp of the most recent refund on this order, or NULL."),
  refunded_units OPTIONS(description="Sum of quantity across refund_line_items_master for this order."),
  refund_amount_native OPTIONS(description="Sum of refund_amount (native currency)."),
  refund_amount_aud OPTIONS(description="Sum of refund_amount in AUD at order-date FX."),
  refund_amount_usd OPTIONS(description="Sum of refund_amount in USD at order-date FX."),
  refund_subtotal_native OPTIONS(description="Sum of refund_subtotal (native currency, excludes tax)."),
  refund_subtotal_aud OPTIONS(description="Sum of refund_subtotal in AUD."),
  net_revenue_native OPTIONS(description="total_price - refund_amount (native currency). Diagnostic: may differ slightly from current_total_price due to tax/timing."),
  net_revenue_from_refunds_aud OPTIONS(description="total_price_aud - refund_amount_aud. DIAGNOSTIC only. Prefer net_revenue_aud (= current_total_price_aud) for reporting."),
  net_revenue_from_refunds_usd OPTIONS(description="USD equivalent of net_revenue_from_refunds_aud. DIAGNOSTIC only."),
  fulfillment_count OPTIONS(description="Number of fulfilment events on this order (0 if none)."),
  successful_fulfillment_count OPTIONS(description="Number of fulfilments with status='success'."),
  first_fulfilled_at OPTIONS(description="UTC timestamp of the earliest successful fulfilment, or NULL."),
  last_fulfilled_at OPTIONS(description="UTC timestamp of the most recent successful fulfilment, or NULL."),
  latest_shipment_status OPTIONS(description="Most recent shipment_status across fulfilments on this order."),
  fulfilled_units OPTIONS(description="Sum of quantity across successful fulfilment_line_items for this order."),
  hours_to_first_fulfillment OPTIONS(description="Hours between created_at and first_fulfilled_at. NULL while unfulfilled."),
  fx_native_to_aud OPTIONS(description="FX multiplier from native currency to AUD on DATE(created_at). Forward-filled across weekends/holidays."),
  fx_usd_to_aud OPTIONS(description="FX multiplier from USD to AUD on DATE(created_at).")
)
OPTIONS(description="Canonical order view. One row per Shopify order. AUD/USD-normalised monetary columns, Sydney-local date buckets, refund+fulfilment rollups, and reactivation flags. Does NOT pre-filter cancelled orders.")
AS
WITH o AS (
  SELECT * FROM `peppermayo.orders_master`
),
-- Pre-aggregate refunds per order so a single row of v_orders
-- exposes lifetime-of-order refund totals. An order can have
-- multiple refund events; we sum them.
refund_agg AS (
  SELECT
    order_id,
    COUNT(*) AS refund_count,
    MIN(processed_at) AS first_refund_at,
    MAX(processed_at) AS last_refund_at,
    SUM(COALESCE(refund_amount, 0)) AS total_refund_amount_native,
    SUM(COALESCE(refund_subtotal, 0)) AS total_refund_subtotal_native
  FROM `peppermayo.refunds_master`
  GROUP BY order_id
),
refund_units AS (
  SELECT
    order_id,
    SUM(COALESCE(quantity, 0)) AS total_refunded_units
  FROM `peppermayo.refund_line_items_master`
  GROUP BY order_id
),
-- Pre-aggregate fulfilments per order.
fulfill_agg AS (
  SELECT
    order_id,
    COUNT(*) AS fulfillment_count,
    COUNTIF(status = 'success') AS successful_fulfillment_count,
    MIN(IF(status = 'success', fulfilled_at, NULL)) AS first_fulfilled_at,
    MAX(IF(status = 'success', fulfilled_at, NULL)) AS last_fulfilled_at,
    -- Most recent shipment_status across all fulfilments on the order.
    ANY_VALUE(shipment_status HAVING MAX updated_at) AS latest_shipment_status
  FROM `peppermayo.fulfillments_master`
  GROUP BY order_id
),
fulfill_units AS (
  SELECT
    order_id,
    SUM(IF(status = 'success', COALESCE(quantity, 0), 0)) AS total_fulfilled_units
  FROM `peppermayo.fulfillment_line_items_master`
  GROUP BY order_id
),
joined AS (
  SELECT
    o.*,
    DATE(o.created_at) AS created_date_utc,
    DATE(o.created_at, "Australia/Sydney") AS created_date_sydney,
    DATE_TRUNC(DATE(o.created_at, "Australia/Sydney"), MONTH) AS created_month_sydney,
    fx_native.rate_to_aud AS fx_native_to_aud,
    fx_usd.rate_to_aud AS fx_usd_to_aud,
    ra.refund_count,
    ra.first_refund_at,
    ra.last_refund_at,
    ra.total_refund_amount_native,
    ra.total_refund_subtotal_native,
    ru.total_refunded_units,
    fa.fulfillment_count,
    fa.successful_fulfillment_count,
    fa.first_fulfilled_at,
    fa.last_fulfilled_at,
    fa.latest_shipment_status,
    fu.total_fulfilled_units,
    -- Customer-scoped order sequence (non-cancelled only). NULL for guests.
    CASE WHEN o.customer_id IS NOT NULL AND o.cancelled_at IS NULL
         THEN ROW_NUMBER() OVER (
                PARTITION BY o.customer_id
                ORDER BY IF(o.cancelled_at IS NULL, o.created_at, NULL) NULLS LAST
              )
    END AS customer_order_rank,
    CASE WHEN o.customer_id IS NOT NULL AND o.cancelled_at IS NULL
         THEN LAST_VALUE(IF(o.cancelled_at IS NULL, o.created_at, NULL) IGNORE NULLS) OVER (
                PARTITION BY o.customer_id
                ORDER BY o.created_at
                ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
              )
    END AS previous_order_at
  FROM o
  LEFT JOIN `peppermayo.v_fx_rates_filled` fx_native
    ON fx_native.currency = o.currency
    AND fx_native.rate_date = DATE(o.created_at)
  LEFT JOIN `peppermayo.v_fx_rates_filled` fx_usd
    ON fx_usd.currency = 'USD'
    AND fx_usd.rate_date = DATE(o.created_at)
  LEFT JOIN refund_agg    ra USING (order_id)
  LEFT JOIN refund_units  ru USING (order_id)
  LEFT JOIN fulfill_agg   fa USING (order_id)
  LEFT JOIN fulfill_units fu USING (order_id)
)
SELECT
  store_region,
  order_id,
  customer_id,
  created_at,
  updated_at,
  cancelled_at,
  closed_at,

  created_date_utc,
  created_date_sydney,
  created_month_sydney,

  financial_status,
  fulfillment_status,

  currency,
  presentment_currency,

  -- Native-currency figures, passed through unchanged.
  subtotal_price,
  total_discounts,
  total_tax,
  total_shipping_price,
  total_price,
  current_total_price,

  -- AUD-normalised (multiply native by rate_to_aud).
  SAFE_MULTIPLY(subtotal_price,       fx_native_to_aud) AS subtotal_price_aud,
  SAFE_MULTIPLY(total_discounts,      fx_native_to_aud) AS total_discounts_aud,
  SAFE_MULTIPLY(total_tax,            fx_native_to_aud) AS total_tax_aud,
  SAFE_MULTIPLY(total_shipping_price, fx_native_to_aud) AS total_shipping_price_aud,
  SAFE_MULTIPLY(total_price,          fx_native_to_aud) AS total_price_aud,
  SAFE_MULTIPLY(current_total_price,  fx_native_to_aud) AS current_total_price_aud,

  -- USD-normalised: convert native -> AUD first, then AUD -> USD by
  -- dividing by USD's rate_to_aud on the same date.
  SAFE_DIVIDE(SAFE_MULTIPLY(subtotal_price,       fx_native_to_aud), fx_usd_to_aud) AS subtotal_price_usd,
  SAFE_DIVIDE(SAFE_MULTIPLY(total_discounts,      fx_native_to_aud), fx_usd_to_aud) AS total_discounts_usd,
  SAFE_DIVIDE(SAFE_MULTIPLY(total_tax,            fx_native_to_aud), fx_usd_to_aud) AS total_tax_usd,
  SAFE_DIVIDE(SAFE_MULTIPLY(total_shipping_price, fx_native_to_aud), fx_usd_to_aud) AS total_shipping_price_usd,
  SAFE_DIVIDE(SAFE_MULTIPLY(total_price,          fx_native_to_aud), fx_usd_to_aud) AS total_price_usd,
  SAFE_DIVIDE(SAFE_MULTIPLY(current_total_price,  fx_native_to_aud), fx_usd_to_aud) AS current_total_price_usd,

  -- Canonical revenue aliases (stable names for BI / LLM consumption).
  SAFE_MULTIPLY(total_price,         fx_native_to_aud) AS gross_revenue_aud,
  SAFE_DIVIDE(SAFE_MULTIPLY(total_price,         fx_native_to_aud), fx_usd_to_aud) AS gross_revenue_usd,
  SAFE_MULTIPLY(current_total_price, fx_native_to_aud) AS net_revenue_aud,
  SAFE_DIVIDE(SAFE_MULTIPLY(current_total_price, fx_native_to_aud), fx_usd_to_aud) AS net_revenue_usd,

  -- Tags and discount codes as arrays. Empty strings -> empty arrays so
  -- UNNEST doesn't produce a spurious empty row. Codes are TRIMmed and
  -- empty entries filtered — the raw column sometimes contains "A, B"
  -- (with space) vs "A,B".
  IF(tags IS NULL OR tags = '', [], SPLIT(tags, ', ')) AS tags_array,
  IF(discount_codes IS NULL OR discount_codes = '',
     [],
     ARRAY(SELECT TRIM(c) FROM UNNEST(SPLIT(discount_codes, ',')) AS c WHERE TRIM(c) != '')
  ) AS discount_codes_array,
  tags,
  discount_codes,

  -- Friendly channel name. Everything else stays as-is.
  CASE
    WHEN source_name = 'web'                 THEN 'Online Store'
    WHEN source_name = 'pos'                 THEN 'Point of Sale'
    WHEN source_name = 'shopify_draft_order' THEN 'Manual / Draft'
    WHEN source_name = 'iphone'              THEN 'Shopify Mobile'
    WHEN source_name = 'android'             THEN 'Shopify Mobile'
    WHEN SAFE_CAST(source_name AS INT64) IS NOT NULL THEN 'Third-party App'
    WHEN source_name IS NULL OR source_name = '' THEN 'Unknown'
    ELSE source_name
  END AS source_name_friendly,
  source_name,

  order_number,
  cancel_reason,
  payment_gateway,
  device_type,
  referring_site,

  shipping_city,
  shipping_province,
  shipping_country_code,

  total_weight_grams,
  hashed_email,

  -- Convenience booleans the LLM often needs.
  cancelled_at IS NOT NULL AS is_cancelled,
  financial_status IN ('refunded', 'voided') AS is_refunded_full,
  financial_status = 'partially_refunded' AS is_refunded_partial,
  fulfillment_status = 'unfulfilled' AS is_unfulfilled,

  -- Per-order customer history. Use these for per-month repeat/reactivation
  -- questions instead of the lifetime flags on customers_master.
  customer_order_rank IS NOT NULL AND customer_order_rank > 1 AS is_returning_customer_order,
  previous_order_at,
  CASE WHEN previous_order_at IS NOT NULL
       THEN DATE_DIFF(DATE(created_at), DATE(previous_order_at), DAY)
  END AS days_since_previous_order,
  CASE WHEN previous_order_at IS NOT NULL
       THEN DATE_DIFF(DATE(created_at), DATE(previous_order_at), DAY) > 180
  END AS is_reactivation_order,

  -- Refund rollups (from refunds_master / refund_line_items_master).
  -- NULL -> 0 so SUM/AVG downstream doesn't need COALESCE.
  COALESCE(refund_count, 0) AS refund_count,
  first_refund_at,
  last_refund_at,
  COALESCE(total_refunded_units, 0) AS refunded_units,
  COALESCE(total_refund_amount_native, 0) AS refund_amount_native,
  SAFE_MULTIPLY(COALESCE(total_refund_amount_native, 0),   fx_native_to_aud) AS refund_amount_aud,
  SAFE_DIVIDE(SAFE_MULTIPLY(COALESCE(total_refund_amount_native, 0), fx_native_to_aud), fx_usd_to_aud) AS refund_amount_usd,
  COALESCE(total_refund_subtotal_native, 0) AS refund_subtotal_native,
  SAFE_MULTIPLY(COALESCE(total_refund_subtotal_native, 0), fx_native_to_aud) AS refund_subtotal_aud,

  -- Net-of-refund revenue DERIVED from refunds_master. This is
  -- DIAGNOSTIC only — for reporting prefer net_revenue_aud (=
  -- current_total_price_aud), which is Shopify's own post-refund
  -- figure and reconciles with Shopify's dashboards.
  total_price - COALESCE(total_refund_amount_native, 0) AS net_revenue_native,
  SAFE_MULTIPLY(total_price - COALESCE(total_refund_amount_native, 0), fx_native_to_aud) AS net_revenue_from_refunds_aud,
  SAFE_DIVIDE(SAFE_MULTIPLY(total_price - COALESCE(total_refund_amount_native, 0), fx_native_to_aud), fx_usd_to_aud) AS net_revenue_from_refunds_usd,

  -- Fulfilment rollups (from fulfillments_master / fulfillment_line_items_master).
  COALESCE(fulfillment_count, 0) AS fulfillment_count,
  COALESCE(successful_fulfillment_count, 0) AS successful_fulfillment_count,
  first_fulfilled_at,
  last_fulfilled_at,
  latest_shipment_status,
  COALESCE(total_fulfilled_units, 0) AS fulfilled_units,
  -- Shipping lead-time (time from order creation to first successful
  -- fulfilment), in hours. NULL while the order is still unfulfilled.
  SAFE_CAST(TIMESTAMP_DIFF(first_fulfilled_at, created_at, HOUR) AS INT64) AS hours_to_first_fulfillment,

  -- FX context, useful for debugging "why is this number off".
  fx_native_to_aud,
  fx_usd_to_aud
FROM joined;
