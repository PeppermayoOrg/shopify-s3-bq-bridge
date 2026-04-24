-- v_fulfillments — fulfilment events with derived time-to-ship.
--
-- Adds order-level context (store_region is already denormalised on
-- the master; we pull in customer_id here so CS queries don't need a
-- separate join back to v_orders).
--
-- `hours_to_ship` measures ordered-to-shipped lead time for
-- successful fulfilments only. NULL for any non-success status.

CREATE OR REPLACE VIEW `peppermayo.v_fulfillments`
(
  fulfillment_id OPTIONS(description="Shopify fulfilment ID. Primary key."),
  order_id OPTIONS(description="Parent order ID."),
  store_region OPTIONS(description="Storefront region (denormalised)."),
  order_created_at OPTIONS(description="Parent order's created_at (UTC)."),
  created_at OPTIONS(description="UTC timestamp the fulfilment record was created."),
  fulfilled_at OPTIONS(description="UTC timestamp the shipment was dispatched (NULL while in-flight)."),
  fulfilled_date_utc OPTIONS(description="DATE of fulfilled_at in UTC."),
  fulfilled_date_sydney OPTIONS(description="DATE of fulfilled_at in Australia/Sydney."),
  status OPTIONS(description="Fulfilment status: success / cancelled / error / failure / open / pending."),
  is_successful OPTIONS(description="TRUE when status='success'."),
  shipment_status OPTIONS(description="Carrier shipment status: label_printed / in_transit / out_for_delivery / delivered / etc."),
  is_delivered OPTIONS(description="TRUE when shipment_status='delivered'."),
  tracking_company OPTIONS(description="Carrier name (e.g. Australia Post, DHL)."),
  tracking_number OPTIONS(description="Single tracking number."),
  tracking_numbers OPTIONS(description="Comma-separated tracking numbers when multiple parcels."),
  tracking_url OPTIONS(description="Carrier tracking URL."),
  service OPTIONS(description="Shipping service level (e.g. 'express', 'standard')."),
  location_id OPTIONS(description="Shopify location ID the fulfilment shipped from."),
  name OPTIONS(description="Fulfilment label/name, e.g. '#1001.1' for split shipments."),
  hours_to_ship OPTIONS(description="Hours between order_created_at and fulfilled_at. ONLY populated for status='success'."),
  customer_id OPTIONS(description="Parent order's customer_id."),
  currency OPTIONS(description="Parent order's native currency."),
  total_price_aud OPTIONS(description="Parent order's total_price_aud (gross revenue) for quick context."),
  updated_at OPTIONS(description="UTC timestamp of the most recent Shopify-side mutation.")
)
OPTIONS(description="Fulfilment events with derived time-to-ship and parent order context. One row per fulfilment.")
AS
SELECT
  f.fulfillment_id,
  f.order_id,
  f.store_region,
  f.order_created_at,
  f.created_at,
  f.fulfilled_at,
  DATE(f.fulfilled_at) AS fulfilled_date_utc,
  DATE(f.fulfilled_at, "Australia/Sydney") AS fulfilled_date_sydney,
  f.status,
  f.status = 'success' AS is_successful,
  f.shipment_status,
  f.shipment_status = 'delivered' AS is_delivered,
  f.tracking_company,
  f.tracking_number,
  f.tracking_numbers,
  f.tracking_url,
  f.service,
  f.location_id,
  f.name,
  CASE
    WHEN f.status = 'success' AND f.fulfilled_at IS NOT NULL
    THEN TIMESTAMP_DIFF(f.fulfilled_at, f.order_created_at, HOUR)
  END AS hours_to_ship,
  o.customer_id,
  o.currency,
  o.total_price_aud,
  f.updated_at
FROM `peppermayo.fulfillments_master` f
LEFT JOIN `peppermayo.v_orders` o USING (order_id);
