-- Master Tables
CREATE TABLE `peppermayo.orders_master` (
  store_region STRING,
  order_id INT64,
  customer_id STRING,
  created_at TIMESTAMP,
  updated_at TIMESTAMP,
  cancelled_at TIMESTAMP,
  closed_at TIMESTAMP,
  financial_status STRING,
  fulfillment_status STRING,
  currency STRING,
  subtotal_price FLOAT64,
  total_discounts FLOAT64,
  total_tax FLOAT64,
  total_shipping_price FLOAT64,
  total_price FLOAT64,
  tags STRING,
  discount_codes STRING
)
PARTITION BY DATE(created_at)
CLUSTER BY store_region, financial_status;

CREATE TABLE `peppermayo.order_items_master` (
  line_item_id INT64,
  order_id INT64,
  product_id INT64,
  variant_id INT64,
  sku STRING,
  name STRING,
  quantity INT64,
  price FLOAT64,
  size STRING,
  colour STRING
)
CLUSTER BY order_id, sku;