-- Staging tables for refunds. All columns nullable; types match the
-- master tables so DTS loads succeed even when individual fields are
-- absent from a day's CSV slice.

CREATE TABLE IF NOT EXISTS `peppermayo.staging_refunds` (
  refund_id INT64,
  order_id INT64,
  store_region STRING,
  order_created_at TIMESTAMP,
  created_at TIMESTAMP,
  processed_at TIMESTAMP,
  currency STRING,
  refund_subtotal FLOAT64,
  refund_total_tax FLOAT64,
  refund_amount FLOAT64,
  note STRING,
  user_id INT64
)
OPTIONS(description="DTS load target for daily/refunds/*.csv. Truncated and rewritten daily. Use refunds_master for querying.");

CREATE TABLE IF NOT EXISTS `peppermayo.staging_refund_line_items` (
  refund_line_item_id INT64,
  refund_id INT64,
  order_id INT64,
  line_item_id INT64,
  store_region STRING,
  order_created_at TIMESTAMP,
  refund_processed_at TIMESTAMP,
  quantity INT64,
  subtotal FLOAT64,
  total_tax FLOAT64,
  restock_type STRING
)
OPTIONS(description="DTS load target for daily/refund_items/*.csv. Truncated and rewritten daily.");
