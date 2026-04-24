-- v_order_items — enriched line-item view.
--
-- Joins order_items_master to v_orders on order_id to surface
-- AUD/USD-normalised unit prices and line revenue, and to
-- refunds_master / fulfillment_line_items_master to expose
-- refund-adjusted and fulfilment-adjusted quantities.
--
-- Prefer this view over order_items_master for anything where
-- currency normalisation or refund accounting matters.
--
-- Quantity definitions
-- --------------------
--    quantity          — units ordered at purchase time (never changes).
--    quantity_refunded — units returned via Shopify refunds.
--    quantity_fulfilled — units actually shipped (successful fulfilments).
--    quantity_net      — quantity minus quantity_refunded, floored at 0.
--                        This is the right number for "units sold" /
--                        sell-through / inventory depletion analysis.

CREATE OR REPLACE VIEW `peppermayo.v_order_items`
(
  line_item_id OPTIONS(description="Shopify line-item ID. Globally unique across stores. Primary key."),
  order_id OPTIONS(description="Parent order ID. Join key to v_orders."),
  store_region OPTIONS(description="Storefront region (AU/US/UK/CA/EU), denormalised from parent order."),
  created_at OPTIONS(description="Parent order's created_at (UTC). Denormalised for partition pruning."),
  created_date_utc OPTIONS(description="DATE of created_at in UTC."),
  created_date_sydney OPTIONS(description="DATE of created_at in Australia/Sydney."),
  product_id OPTIONS(description="Shopify product ID, scoped per store_region."),
  variant_id OPTIONS(description="Shopify variant ID, scoped per store_region."),
  sku OPTIONS(description="Seller SKU. Most reliable cross-store join key for 'same physical product'."),
  name OPTIONS(description="Human-readable product + variant name as shown on the order."),
  size OPTIONS(description="Parsed size from Shopify's 'Colour / Size' variant_title."),
  colour OPTIONS(description="Parsed colour from Shopify's 'Colour / Size' variant_title."),
  vendor OPTIONS(description="Brand / vendor as set on the Shopify product."),
  gift_card OPTIONS(description="TRUE if the line item is a gift-card product. Typically excluded from revenue metrics."),
  quantity OPTIONS(description="Units ORDERED at purchase time. NOT net of refunds. For refund-adjusted units use quantity_net; for units shipped use quantity_fulfilled."),
  quantity_refunded OPTIONS(description="Sum of units returned via refund_line_items_master for this line."),
  quantity_fulfilled OPTIONS(description="Sum of units shipped via successful fulfilment_line_items for this line."),
  quantity_net OPTIONS(description="quantity - quantity_refunded, floored at 0. Correct measure of 'units sold' / sell-through / inventory depletion."),
  line_revenue_native OPTIONS(description="price * quantity. NATIVE currency. Gross (pre-refund)."),
  line_net_revenue_native OPTIONS(description="price * quantity_net. NATIVE currency. Refund-adjusted."),
  total_discount OPTIONS(description="Total discount applied to this line. NATIVE currency."),
  price OPTIONS(description="Unit price in the parent order's NATIVE currency."),
  compare_at_price OPTIONS(description="Original RRP before markdown. NULL if not on sale. NATIVE currency."),
  price_aud OPTIONS(description="Unit price in AUD at order-date FX."),
  compare_at_price_aud OPTIONS(description="compare_at_price in AUD."),
  total_discount_aud OPTIONS(description="total_discount in AUD."),
  line_revenue_aud OPTIONS(description="GROSS line revenue in AUD (pre-refund)."),
  line_net_revenue_aud OPTIONS(description="NET line revenue in AUD (refund-adjusted via quantity_net)."),
  refund_subtotal_aud OPTIONS(description="Sum of refund_line_items_master.subtotal for this line, in AUD at order-date FX."),
  price_usd OPTIONS(description="Unit price in USD."),
  compare_at_price_usd OPTIONS(description="compare_at_price in USD."),
  total_discount_usd OPTIONS(description="total_discount in USD."),
  line_revenue_usd OPTIONS(description="GROSS line revenue in USD."),
  line_net_revenue_usd OPTIONS(description="NET line revenue in USD (refund-adjusted)."),
  currency OPTIONS(description="Parent order's native currency."),
  financial_status OPTIONS(description="Parent order's financial_status."),
  fulfillment_status OPTIONS(description="Parent order's fulfillment_status."),
  customer_id OPTIONS(description="Parent order's customer_id. NULL for guest checkouts."),
  is_cancelled OPTIONS(description="TRUE if parent order is cancelled. v_order_items does NOT pre-filter cancellations."),
  is_refunded_full OPTIONS(description="Parent order's is_refunded_full."),
  is_refunded_partial OPTIONS(description="Parent order's is_refunded_partial."),
  latest_shipment_status OPTIONS(description="Parent order's latest_shipment_status.")
)
OPTIONS(description="Line-item view with AUD/USD-normalised and refund/fulfilment-adjusted quantities. Does NOT pre-filter cancelled orders or gift cards — add WHERE NOT is_cancelled AND NOT gift_card as needed.")
AS
WITH refunded_per_line AS (
  SELECT line_item_id,
         SUM(COALESCE(quantity, 0)) AS quantity_refunded,
         SUM(COALESCE(subtotal, 0)) AS refund_subtotal_native,
         SUM(COALESCE(total_tax, 0)) AS refund_tax_native
  FROM `peppermayo.refund_line_items_master`
  GROUP BY line_item_id
),
fulfilled_per_line AS (
  SELECT line_item_id,
         SUM(IF(status = 'success', COALESCE(quantity, 0), 0)) AS quantity_fulfilled
  FROM `peppermayo.fulfillment_line_items_master`
  GROUP BY line_item_id
)
SELECT
  i.line_item_id,
  i.order_id,
  o.store_region,
  o.created_at,
  DATE(o.created_at) AS created_date_utc,
  DATE(o.created_at, "Australia/Sydney") AS created_date_sydney,

  i.product_id,
  i.variant_id,
  i.sku,
  i.name,
  i.size,
  i.colour,
  i.vendor,
  i.gift_card,

  i.quantity,
  COALESCE(r.quantity_refunded,  0) AS quantity_refunded,
  COALESCE(f.quantity_fulfilled, 0) AS quantity_fulfilled,
  GREATEST(i.quantity - COALESCE(r.quantity_refunded, 0), 0) AS quantity_net,

  -- Raw line revenue in native currency (ordered qty).
  i.price * i.quantity AS line_revenue_native,
  -- Refund-adjusted line revenue (net qty).
  i.price * GREATEST(i.quantity - COALESCE(r.quantity_refunded, 0), 0) AS line_net_revenue_native,
  i.total_discount,

  -- Native-currency price fields.
  i.price,
  i.compare_at_price,

  -- AUD-normalised.
  SAFE_MULTIPLY(i.price, o.fx_native_to_aud) AS price_aud,
  SAFE_MULTIPLY(i.compare_at_price, o.fx_native_to_aud) AS compare_at_price_aud,
  SAFE_MULTIPLY(i.total_discount, o.fx_native_to_aud) AS total_discount_aud,
  SAFE_MULTIPLY(i.price * i.quantity, o.fx_native_to_aud) AS line_revenue_aud,
  SAFE_MULTIPLY(i.price * GREATEST(i.quantity - COALESCE(r.quantity_refunded, 0), 0), o.fx_native_to_aud) AS line_net_revenue_aud,
  SAFE_MULTIPLY(COALESCE(r.refund_subtotal_native, 0), o.fx_native_to_aud) AS refund_subtotal_aud,

  -- USD-normalised.
  SAFE_DIVIDE(SAFE_MULTIPLY(i.price, o.fx_native_to_aud), o.fx_usd_to_aud) AS price_usd,
  SAFE_DIVIDE(SAFE_MULTIPLY(i.compare_at_price, o.fx_native_to_aud), o.fx_usd_to_aud) AS compare_at_price_usd,
  SAFE_DIVIDE(SAFE_MULTIPLY(i.total_discount, o.fx_native_to_aud), o.fx_usd_to_aud) AS total_discount_usd,
  SAFE_DIVIDE(SAFE_MULTIPLY(i.price * i.quantity, o.fx_native_to_aud), o.fx_usd_to_aud) AS line_revenue_usd,
  SAFE_DIVIDE(SAFE_MULTIPLY(i.price * GREATEST(i.quantity - COALESCE(r.quantity_refunded, 0), 0), o.fx_native_to_aud), o.fx_usd_to_aud) AS line_net_revenue_usd,

  -- Order-level context so the LLM can filter items without joining back.
  o.currency,
  o.financial_status,
  o.fulfillment_status,
  o.customer_id,
  o.is_cancelled,
  o.is_refunded_full,
  o.is_refunded_partial,
  o.latest_shipment_status
FROM `peppermayo.order_items_master` i
JOIN `peppermayo.v_orders` o USING (order_id)
LEFT JOIN refunded_per_line  r ON r.line_item_id = i.line_item_id
LEFT JOIN fulfilled_per_line f ON f.line_item_id = i.line_item_id;
