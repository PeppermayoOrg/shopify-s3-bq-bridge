-- v_monthly_sales — month × region grain. Sydney-local months.
--
-- ALREADY excludes cancelled orders — do NOT add WHERE NOT is_cancelled.
--
-- Revenue convention:
--    gross_revenue_aud = SUM(total_price_aud)           (pre-refund)
--    net_revenue_aud   = SUM(current_total_price_aud)   (Shopify's post-refund; CANONICAL)

CREATE OR REPLACE VIEW `peppermayo.v_monthly_sales`
(
  sales_month OPTIONS(description="Sydney-local first-of-month DATE."),
  store_region OPTIONS(description="Storefront region: AU, US, UK, CA, EU."),
  orders OPTIONS(description="Count of non-cancelled orders in this month×region."),
  distinct_customers OPTIONS(description="Distinct identified customer_ids. EXCLUDES guest checkouts."),
  distinct_customers_incl_guests OPTIONS(description="Distinct customers including guests via hashed_email."),
  gross_revenue_aud OPTIONS(description="SUM(total_price_aud). Pre-refund."),
  gross_revenue_usd OPTIONS(description="SUM(total_price_usd)."),
  net_revenue_aud OPTIONS(description="SUM(current_total_price_aud). CANONICAL net revenue."),
  net_revenue_usd OPTIONS(description="SUM(current_total_price_usd). CANONICAL net revenue in USD."),
  discounts_aud OPTIONS(description="SUM(total_discounts_aud)."),
  aov_aud OPTIONS(description="Average order value in AUD."),
  aov_usd OPTIONS(description="Average order value in USD.")
)
OPTIONS(description="Pre-aggregated monthly sales by region. Sydney-local months. ALREADY excludes cancelled orders.")
AS
SELECT
  created_month_sydney AS sales_month,
  store_region,
  COUNT(*) AS orders,
  COUNT(DISTINCT customer_id) AS distinct_customers,
  COUNT(DISTINCT COALESCE(customer_id, CONCAT('guest:', hashed_email))) AS distinct_customers_incl_guests,
  SUM(total_price_aud)         AS gross_revenue_aud,
  SUM(total_price_usd)         AS gross_revenue_usd,
  SUM(current_total_price_aud) AS net_revenue_aud,
  SUM(current_total_price_usd) AS net_revenue_usd,
  SUM(total_discounts_aud)     AS discounts_aud,
  SAFE_DIVIDE(SUM(total_price_aud), COUNT(*)) AS aov_aud,
  SAFE_DIVIDE(SUM(total_price_usd), COUNT(*)) AS aov_usd
FROM `peppermayo.v_orders`
WHERE NOT is_cancelled
GROUP BY sales_month, store_region;
