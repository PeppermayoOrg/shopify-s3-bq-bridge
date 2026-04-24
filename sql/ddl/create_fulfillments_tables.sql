-- Fulfilment master tables.
--
-- One row per fulfilment (shipment) in fulfillments_master, one row
-- per (fulfilment, line_item) in fulfillment_line_items_master.
-- Shipped units, tracking, and delivery status live here.
--
-- Shopify uses "fulfillments" (US spelling) as the API noun; we keep
-- that spelling in table/column names to stay 1:1 with the source.

CREATE TABLE IF NOT EXISTS `peppermayo.fulfillments_master` (
  fulfillment_id INT64 NOT NULL OPTIONS(description="Shopify fulfillment ID. Primary key."),
  order_id INT64 NOT NULL OPTIONS(description="Parent order. Join to orders_master / v_orders."),
  store_region STRING NOT NULL OPTIONS(description="Storefront region of the parent order."),
  order_created_at TIMESTAMP NOT NULL OPTIONS(description="UTC created_at of the parent order. Denormalised for partitioning."),
  created_at TIMESTAMP OPTIONS(description="UTC timestamp the fulfilment record was created (label generated, items picked)."),
  fulfilled_at TIMESTAMP OPTIONS(description="UTC timestamp the fulfilment was marked as shipped. Prefer this over created_at for 'when did we ship?' reporting."),
  status STRING OPTIONS(description="Fulfilment status: one of 'pending', 'open', 'success', 'cancelled', 'error', 'failure'. Only 'success' means shipped."),
  shipment_status STRING OPTIONS(description="Carrier-reported status: NULL (none), 'label_printed', 'label_purchased', 'attempted_delivery', 'ready_for_pickup', 'confirmed', 'in_transit', 'out_for_delivery', 'delivered', 'failure'."),
  tracking_company STRING OPTIONS(description="Carrier name reported by Shopify (e.g. 'Australia Post', 'DHL Express'). Free-text; values are not normalised."),
  tracking_number STRING OPTIONS(description="First tracking number on the fulfilment. NULL if none. Use tracking_numbers array for multi-parcel shipments."),
  tracking_numbers ARRAY<STRING> OPTIONS(description="All tracking numbers on the fulfilment. Multi-parcel shipments have >1."),
  tracking_url STRING OPTIONS(description="First tracking URL on the fulfilment, if provided."),
  service STRING OPTIONS(description="Fulfilment service handle (e.g. 'manual', 'shipstation'). Indicates which system shipped the order."),
  location_id INT64 OPTIONS(description="Shopify location ID the fulfilment shipped from, or NULL."),
  name STRING OPTIONS(description="Shopify fulfilment name, e.g. '#1001.1'. Useful for CS lookups."),
  updated_at TIMESTAMP NOT NULL OPTIONS(description="UTC timestamp this warehouse row was last upserted.")
)
PARTITION BY DATE(order_created_at)
CLUSTER BY store_region, order_id
OPTIONS(description="One row per fulfilment event (an order can have multiple — split shipments). Sourced from order.fulfillments[].");

CREATE TABLE IF NOT EXISTS `peppermayo.fulfillment_line_items_master` (
  fulfillment_id INT64 NOT NULL OPTIONS(description="Parent fulfilment ID. Join to fulfillments_master."),
  line_item_id INT64 NOT NULL OPTIONS(description="Original line item that was fulfilled. Join to order_items_master."),
  order_id INT64 NOT NULL OPTIONS(description="Parent order ID. Join to orders_master."),
  store_region STRING NOT NULL OPTIONS(description="Storefront region of the parent order."),
  order_created_at TIMESTAMP NOT NULL OPTIONS(description="UTC created_at of the parent order. Denormalised for partitioning."),
  fulfilled_at TIMESTAMP OPTIONS(description="UTC timestamp the parent fulfilment was shipped."),
  status STRING OPTIONS(description="Status of the parent fulfilment at the time the row was written."),
  quantity INT64 NOT NULL OPTIONS(description="Units of this line item included in this fulfilment."),
  updated_at TIMESTAMP NOT NULL OPTIONS(description="UTC timestamp this warehouse row was last upserted.")
)
PARTITION BY DATE(order_created_at)
CLUSTER BY store_region, order_id, line_item_id
OPTIONS(description="One row per (fulfillment, line_item). Primary key is (fulfillment_id, line_item_id). Drives fulfilled-units metrics and 'what's actually shipped vs ordered' gap analysis.");
