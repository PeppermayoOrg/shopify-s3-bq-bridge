-- v_product_performance — month × store × product sales rollup.
--
-- Sits on top of v_order_items so units and revenue are already
-- refund-adjusted (quantity_net / line_net_revenue_aud) and
-- currency-normalised. LEFT JOIN to products_master picks up
-- product_type, vendor, title without forcing one — items whose
-- product was deleted from the catalog since the order still appear
-- (with NULL product metadata) rather than disappearing.

CREATE OR REPLACE VIEW `peppermayo.v_product_performance`
(
  sales_date OPTIONS(description="Sydney-local DATE of the parent order."),
  sales_month OPTIONS(description="Sydney-local first-of-month DATE."),
  store_region OPTIONS(description="Storefront region: AU, US, UK, CA, EU."),
  product_id OPTIONS(description="Shopify product ID, scoped per store_region."),
  product_title OPTIONS(description="Product display name (NULL if the product was deleted from the catalog since purchase)."),
  product_handle OPTIONS(description="Product URL handle."),
  product_type OPTIONS(description="Shopify product_type."),
  vendor OPTIONS(description="Brand / vendor."),
  units_ordered OPTIONS(description="SUM(quantity). Raw units ordered, pre-refund."),
  units_refunded OPTIONS(description="SUM(quantity_refunded). Units returned."),
  units_fulfilled OPTIONS(description="SUM(quantity_fulfilled). Units shipped via successful fulfilments."),
  units_net OPTIONS(description="SUM(quantity_net) = units_ordered - units_refunded (floored at 0). CANONICAL units sold."),
  gross_revenue_aud OPTIONS(description="SUM(line_revenue_aud). Pre-refund line revenue in AUD."),
  net_revenue_aud OPTIONS(description="SUM(line_net_revenue_aud). Refund-adjusted line revenue in AUD. CANONICAL for product performance."),
  refund_subtotal_aud OPTIONS(description="SUM(refund_subtotal_aud) in AUD."),
  gross_revenue_usd OPTIONS(description="SUM(line_revenue_usd)."),
  net_revenue_usd OPTIONS(description="SUM(line_net_revenue_usd). CANONICAL net revenue in USD."),
  orders_with_product OPTIONS(description="Distinct parent orders containing this product on this date."),
  distinct_customers OPTIONS(description="Distinct identified customer_ids. EXCLUDES guest checkouts.")
)
OPTIONS(description="Product performance by day × region × product. ALREADY excludes cancelled orders AND gift cards. units_net and net_revenue_aud are refund-adjusted.")
AS
SELECT
  i.created_date_sydney                                       AS sales_date,
  DATE_TRUNC(i.created_date_sydney, MONTH)                    AS sales_month,
  i.store_region,
  i.product_id,
  p.title                                                     AS product_title,
  p.handle                                                    AS product_handle,
  p.product_type,
  p.vendor,
  SUM(i.quantity)                                             AS units_ordered,
  SUM(i.quantity_refunded)                                    AS units_refunded,
  SUM(i.quantity_fulfilled)                                   AS units_fulfilled,
  SUM(i.quantity_net)                                         AS units_net,
  SUM(i.line_revenue_aud)                                     AS gross_revenue_aud,
  SUM(i.line_net_revenue_aud)                                 AS net_revenue_aud,
  SUM(i.refund_subtotal_aud)                                  AS refund_subtotal_aud,
  SUM(i.line_revenue_usd)                                     AS gross_revenue_usd,
  SUM(i.line_net_revenue_usd)                                 AS net_revenue_usd,
  COUNT(DISTINCT i.order_id)                                  AS orders_with_product,
  COUNT(DISTINCT i.customer_id)                               AS distinct_customers
FROM `peppermayo.v_order_items` i
LEFT JOIN `peppermayo.products_master` p
  ON p.product_id   = i.product_id
  AND p.store_region = i.store_region
WHERE NOT i.is_cancelled
  AND NOT i.gift_card
GROUP BY sales_date, sales_month, i.store_region, i.product_id, p.title, p.handle, p.product_type, p.vendor;
