-- v_refunds — AUD/USD-normalised refunds.
--
-- One row per refund event. FX conversion uses the **order's**
-- created_at date, not the refund date, so the numbers reconcile
-- against v_orders.total_refund_amount_aud. If you want to value
-- refunds at the rate on the day the money actually left the
-- business, use refunds_master directly and join fx_rates_master
-- on processed_at.

CREATE OR REPLACE VIEW `peppermayo.v_refunds`
(
  refund_id OPTIONS(description="Shopify refund ID. Primary key."),
  order_id OPTIONS(description="Parent order ID."),
  store_region OPTIONS(description="Storefront region (denormalised from parent order)."),
  order_created_at OPTIONS(description="Parent order's created_at (UTC). FX conversion uses this date, NOT processed_at."),
  created_at OPTIONS(description="UTC timestamp the refund record was created in Shopify."),
  processed_at OPTIONS(description="UTC timestamp the refund was actually processed (money out)."),
  processed_date_utc OPTIONS(description="DATE of processed_at in UTC."),
  processed_date_sydney OPTIONS(description="DATE of processed_at in Australia/Sydney."),
  processed_month_sydney OPTIONS(description="Sydney-local first-of-month DATE."),
  currency OPTIONS(description="ISO-4217 native currency."),
  refund_subtotal OPTIONS(description="Refund subtotal (excl. tax) in NATIVE currency."),
  refund_total_tax OPTIONS(description="Refund tax portion in NATIVE currency."),
  refund_amount OPTIONS(description="Refund total (incl. tax) in NATIVE currency."),
  refund_amount_aud OPTIONS(description="refund_amount converted to AUD at ORDER-date FX (not refund date)."),
  refund_subtotal_aud OPTIONS(description="refund_subtotal in AUD at order-date FX."),
  refund_amount_usd OPTIONS(description="refund_amount in USD at order-date FX."),
  note OPTIONS(description="Free-text refund reason/note entered by CS."),
  user_id OPTIONS(description="Shopify staff user who issued the refund, or NULL for customer-initiated."),
  updated_at OPTIONS(description="UTC timestamp of the most recent Shopify-side mutation.")
)
OPTIONS(description="Refund events with AUD/USD normalisation. One row per refund. FX uses order-date so totals reconcile with v_orders.refund_amount_aud.")
AS
SELECT
  r.refund_id,
  r.order_id,
  r.store_region,
  r.order_created_at,
  r.created_at,
  r.processed_at,
  DATE(r.processed_at) AS processed_date_utc,
  DATE(r.processed_at, "Australia/Sydney") AS processed_date_sydney,
  DATE_TRUNC(DATE(r.processed_at, "Australia/Sydney"), MONTH) AS processed_month_sydney,
  r.currency,
  r.refund_subtotal,
  r.refund_total_tax,
  r.refund_amount,
  SAFE_MULTIPLY(r.refund_amount,   fx.rate_to_aud) AS refund_amount_aud,
  SAFE_MULTIPLY(r.refund_subtotal, fx.rate_to_aud) AS refund_subtotal_aud,
  SAFE_DIVIDE(SAFE_MULTIPLY(r.refund_amount, fx.rate_to_aud), fx_usd.rate_to_aud) AS refund_amount_usd,
  r.note,
  r.user_id,
  r.updated_at
FROM `peppermayo.refunds_master` r
LEFT JOIN `peppermayo.v_fx_rates_filled` fx
  ON fx.currency = r.currency
  AND fx.rate_date = DATE(r.order_created_at)
LEFT JOIN `peppermayo.v_fx_rates_filled` fx_usd
  ON fx_usd.currency = 'USD'
  AND fx_usd.rate_date = DATE(r.order_created_at);
