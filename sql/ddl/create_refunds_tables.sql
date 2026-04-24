-- Refunds master tables.
--
-- One row per refund event in refunds_master, one row per refunded
-- line item in refund_line_items_master. Both carry store_region and
-- order_created_at denormalised from the parent order so they
-- partition the same way orders_master does (by the parent order's
-- created_at) — which keeps every "refunds for orders in range"
-- query partition-pruned.
--
-- refund_amount_aud / refund_amount_usd are populated at MERGE time
-- by joining v_fx_rates_filled on processed_at. We store the native
-- amount here; the view/merge handles conversion.

CREATE TABLE IF NOT EXISTS `peppermayo.refunds_master` (
  refund_id INT64 NOT NULL OPTIONS(description="Shopify refund ID. Primary key."),
  order_id INT64 NOT NULL OPTIONS(description="Parent order ID. Join to orders_master / v_orders."),
  store_region STRING NOT NULL OPTIONS(description="Storefront region of the parent order (AU/US/UK/CA/EU). Denormalised for partition-pruned filters."),
  order_created_at TIMESTAMP NOT NULL OPTIONS(description="UTC created_at of the parent order. Denormalised so this table can be partitioned/clustered identically to orders_master."),
  created_at TIMESTAMP OPTIONS(description="UTC timestamp the refund was created (Shopify initiated it)."),
  processed_at TIMESTAMP OPTIONS(description="UTC timestamp the refund was processed (money actually returned). Preferred for FX conversion and P&L."),
  currency STRING OPTIONS(description="Refund currency (matches the parent order's currency in practice)."),
  refund_subtotal FLOAT64 OPTIONS(description="Sum of refund_line_items.subtotal in native currency. Item-level refund amount, pre-tax, pre-shipping."),
  refund_total_tax FLOAT64 OPTIONS(description="Sum of refund_line_items.total_tax in native currency."),
  refund_amount FLOAT64 OPTIONS(description="Total refund amount in native currency: SUM of successful `refund` transactions on this refund. Includes shipping refunds and non-line-item adjustments."),
  note STRING OPTIONS(description="Free-text note the CS rep entered when processing the refund."),
  user_id INT64 OPTIONS(description="Shopify staff user who processed the refund, or NULL for app-driven refunds."),
  updated_at TIMESTAMP NOT NULL OPTIONS(description="UTC timestamp this warehouse row was last upserted.")
)
PARTITION BY DATE(order_created_at)
CLUSTER BY store_region, order_id
OPTIONS(description="One row per refund event (an order can have multiple refunds). Sourced from order.refunds[]. Partitioned on the parent order's created_at to stay aligned with orders_master.");

CREATE TABLE IF NOT EXISTS `peppermayo.refund_line_items_master` (
  refund_line_item_id INT64 NOT NULL OPTIONS(description="Shopify refund_line_item ID. Primary key."),
  refund_id INT64 NOT NULL OPTIONS(description="Parent refund ID. Join to refunds_master."),
  order_id INT64 NOT NULL OPTIONS(description="Parent order ID. Join to orders_master / v_orders."),
  line_item_id INT64 NOT NULL OPTIONS(description="Original line item that was refunded. Join to order_items_master."),
  store_region STRING NOT NULL OPTIONS(description="Storefront region of the parent order."),
  order_created_at TIMESTAMP NOT NULL OPTIONS(description="UTC created_at of the parent order. Denormalised for partitioning."),
  refund_processed_at TIMESTAMP OPTIONS(description="UTC timestamp the parent refund was processed. Denormalised for FX conversion in views."),
  quantity INT64 NOT NULL OPTIONS(description="Units refunded from this line item. Negative of the effect on net units."),
  subtotal FLOAT64 OPTIONS(description="Refunded subtotal for this line in native currency (pre-tax)."),
  total_tax FLOAT64 OPTIONS(description="Refunded tax for this line in native currency."),
  restock_type STRING OPTIONS(description="Shopify restock_type: 'no_restock', 'cancel', 'return', or 'legacy_restock'. 'cancel' + 'return' indicate inventory came back; 'no_restock' means it didn't."),
  updated_at TIMESTAMP NOT NULL OPTIONS(description="UTC timestamp this warehouse row was last upserted.")
)
PARTITION BY DATE(order_created_at)
CLUSTER BY store_region, order_id, line_item_id
OPTIONS(description="One row per (refund, line_item) pair. Drives v_order_items.quantity_net and refund_amount_aud. Sourced from order.refunds[].refund_line_items[].");
