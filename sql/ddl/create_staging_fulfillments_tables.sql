-- Staging tables for fulfilments.

CREATE TABLE IF NOT EXISTS `peppermayo.staging_fulfillments` (
  fulfillment_id INT64,
  order_id INT64,
  store_region STRING,
  order_created_at TIMESTAMP,
  created_at TIMESTAMP,
  fulfilled_at TIMESTAMP,
  status STRING,
  shipment_status STRING,
  tracking_company STRING,
  tracking_number STRING,
  tracking_numbers STRING, -- comma-joined; parsed to ARRAY in merge_fulfillments.sql
  tracking_url STRING,
  service STRING,
  location_id INT64,
  name STRING
)
OPTIONS(description="DTS load target for daily/fulfillments/*.csv. Truncated and rewritten daily.");

CREATE TABLE IF NOT EXISTS `peppermayo.staging_fulfillment_line_items` (
  fulfillment_id INT64,
  line_item_id INT64,
  order_id INT64,
  store_region STRING,
  order_created_at TIMESTAMP,
  fulfilled_at TIMESTAMP,
  status STRING,
  quantity INT64
)
OPTIONS(description="DTS load target for daily/fulfillment_items/*.csv. Truncated and rewritten daily.");
