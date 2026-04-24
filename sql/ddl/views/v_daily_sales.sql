-- v_daily_sales — date × region × channel grain.
--
-- Excludes cancelled orders by default. Gift-card line items are
-- included in `orders` and `gross_revenue_*` (this view is order-grain,
-- not item-grain); use v_product_performance if you need gift cards
-- excluded.
--
-- All monetary columns in AUD and USD. Native sums intentionally
-- omitted because the grain includes multiple regions — mixing native
-- currencies here would be misleading.
--
-- Revenue convention (stable across the warehouse):
--    gross_revenue_aud = SUM(total_price_aud)           (pre-refund)
--    net_revenue_aud   = SUM(current_total_price_aud)   (Shopify's post-refund; CANONICAL)

CREATE OR REPLACE VIEW `peppermayo.v_daily_sales`
(
  sales_date OPTIONS(description="Sydney-local DATE (Australia/Sydney) of the order's created_at."),
  store_region OPTIONS(description="Storefront region: AU, US, UK, CA, EU."),
  source_name_friendly OPTIONS(description="Human-readable channel (Online Store / Point of Sale / etc.)."),
  orders OPTIONS(description="Count of non-cancelled orders on this date×region×channel."),
  distinct_customers OPTIONS(description="Distinct identified customer_ids. EXCLUDES guest checkouts. For guest-inclusive counts use distinct_customers_incl_guests."),
  distinct_customers_incl_guests OPTIONS(description="Distinct customers including guests — guests are counted by hashed_email."),
  gross_revenue_aud OPTIONS(description="SUM(total_price_aud). Pre-refund, post-discount, incl. tax+shipping. CANONICAL gross revenue."),
  gross_revenue_usd OPTIONS(description="SUM(total_price_usd). Pre-refund gross revenue in USD."),
  net_revenue_aud OPTIONS(description="SUM(current_total_price_aud). CANONICAL net revenue (Shopify's post-refund figure). Reconciles with Shopify reports."),
  net_revenue_usd OPTIONS(description="SUM(current_total_price_usd). CANONICAL net revenue in USD."),
  discounts_aud OPTIONS(description="SUM(total_discounts_aud)."),
  tax_aud OPTIONS(description="SUM(total_tax_aud)."),
  shipping_aud OPTIONS(description="SUM(total_shipping_price_aud)."),
  aov_aud OPTIONS(description="Average order value in AUD = gross_revenue_aud / orders."),
  aov_usd OPTIONS(description="Average order value in USD = gross_revenue_usd / orders.")
)
OPTIONS(description="Pre-aggregated daily sales by region and channel. ALREADY excludes cancelled orders — do NOT add WHERE NOT is_cancelled. Sydney-local dates.")
AS
SELECT
  created_date_sydney AS sales_date,
  store_region,
  source_name_friendly,
  COUNT(*) AS orders,
  COUNT(DISTINCT customer_id) AS distinct_customers,
  COUNT(DISTINCT COALESCE(customer_id, CONCAT('guest:', hashed_email))) AS distinct_customers_incl_guests,
  SUM(total_price_aud)           AS gross_revenue_aud,
  SUM(total_price_usd)           AS gross_revenue_usd,
  SUM(current_total_price_aud)   AS net_revenue_aud,
  SUM(current_total_price_usd)   AS net_revenue_usd,
  SUM(total_discounts_aud)       AS discounts_aud,
  SUM(total_tax_aud)             AS tax_aud,
  SUM(total_shipping_price_aud)  AS shipping_aud,
  SAFE_DIVIDE(SUM(total_price_aud), COUNT(*)) AS aov_aud,
  SAFE_DIVIDE(SUM(total_price_usd), COUNT(*)) AS aov_usd
FROM `peppermayo.v_orders`
WHERE NOT is_cancelled
GROUP BY sales_date, store_region, source_name_friendly;
