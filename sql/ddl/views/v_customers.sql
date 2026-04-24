-- v_customers — thin view over customers_master.
--
-- customers_master is rebuilt daily by a scheduled query. Keep this
-- view so the LLM / BI tooling can reference the v_* family uniformly
-- and so we can add derived columns (churn bucket, percentile rank,
-- cohort tag) here without rebuilding the underlying table.

CREATE OR REPLACE VIEW `peppermayo.v_customers`
(
  customer_id OPTIONS(description="Shopify customer ID. Primary key."),
  first_order_at OPTIONS(description="UTC timestamp of the customer's first non-cancelled order."),
  last_order_at OPTIONS(description="UTC timestamp of the customer's most recent non-cancelled order."),
  first_order_region OPTIONS(description="Acquisition region. Best available 'where did we acquire them' signal."),
  last_order_region OPTIONS(description="Storefront region of the most recent order."),
  regions_purchased_in OPTIONS(description="Distinct sorted array of storefront regions the customer has ordered from. Use `'UK' IN UNNEST(regions_purchased_in)` to ask 'has this customer ever ordered in UK'."),
  has_multi_region_purchases OPTIONS(description="TRUE if regions_purchased_in has >1 region."),
  first_discount_code OPTIONS(description="First discount code on the customer's first order. Best signal for acquisition attribution."),
  lifetime_orders OPTIONS(description="Count of non-cancelled orders."),
  lifetime_cancelled_orders OPTIONS(description="Count of orders later cancelled."),
  lifetime_units_ordered OPTIONS(description="Units ordered pre-refund (excludes gift cards)."),
  lifetime_units_refunded OPTIONS(description="Units returned via refunds (excludes gift cards)."),
  lifetime_units OPTIONS(description="Units sold = ordered - refunded. CANONICAL."),
  lifetime_return_rate OPTIONS(description="lifetime_units_refunded / lifetime_units_ordered. NULL if none ordered. Use for 'customers who have returned >N% of their items'."),
  lifetime_revenue_aud OPTIONS(description="GROSS lifetime revenue in AUD (pre-refund)."),
  lifetime_revenue_usd OPTIONS(description="GROSS lifetime revenue in USD."),
  lifetime_net_revenue_aud OPTIONS(description="NET lifetime revenue in AUD (Shopify's post-refund figure). CANONICAL LTV measure."),
  lifetime_net_revenue_usd OPTIONS(description="NET lifetime revenue in USD. CANONICAL LTV measure in USD."),
  lifetime_discount_aud OPTIONS(description="Total discounts received across non-cancelled orders, AUD."),
  lifetime_revenue_by_region OPTIONS(description="Per-region revenue breakdown ARRAY<STRUCT<region, gross_revenue_aud, gross_revenue_usd, net_revenue_aud, net_revenue_usd, orders>>. UNNEST to attribute LTV to a specific storefront."),
  avg_order_value_aud OPTIONS(description="lifetime_revenue_aud / lifetime_orders."),
  days_since_last_order OPTIONS(description="CURRENT_DATE() - DATE(last_order_at)."),
  is_repeat_customer OPTIONS(description="LIFETIME flag: lifetime_orders >= 2. For per-month rates use v_orders.is_returning_customer_order."),
  is_churned OPTIONS(description="SNAPSHOT flag: days_since_last_order > 180. For 'came back after churn' use v_orders.is_reactivation_order."),
  refreshed_at OPTIONS(description="UTC timestamp this row was computed."),
  recency_bucket OPTIONS(description="Segmentation bucket derived from days_since_last_order: never / active (<=30d) / lapsing (<=90d) / dormant (<=180d) / churned (>180d)."),
  acquisition_cohort_month_sydney OPTIONS(description="Sydney-local first-of-month DATE of the customer's first order. Join key to v_cohort_retention.cohort_month.")
)
OPTIONS(description="Customer-level view over customers_master. Excludes guest checkouts. Lifetime metrics refreshed daily at ~16:15 UTC.")
AS
SELECT
  customer_id,
  first_order_at,
  last_order_at,
  first_order_region,
  last_order_region,
  regions_purchased_in,
  has_multi_region_purchases,
  first_discount_code,
  lifetime_orders,
  lifetime_cancelled_orders,
  lifetime_units_ordered,
  lifetime_units_refunded,
  lifetime_units,
  lifetime_return_rate,
  lifetime_revenue_aud,
  lifetime_revenue_usd,
  lifetime_net_revenue_aud,
  lifetime_net_revenue_usd,
  lifetime_discount_aud,
  lifetime_revenue_by_region,
  avg_order_value_aud,
  days_since_last_order,
  is_repeat_customer,
  is_churned,
  refreshed_at,
  CASE
    WHEN days_since_last_order IS NULL THEN 'never'
    WHEN days_since_last_order <=  30  THEN 'active'
    WHEN days_since_last_order <=  90  THEN 'lapsing'
    WHEN days_since_last_order <= 180  THEN 'dormant'
    ELSE 'churned'
  END AS recency_bucket,
  DATE_TRUNC(DATE(first_order_at, "Australia/Sydney"), MONTH) AS acquisition_cohort_month_sydney
FROM `peppermayo.customers_master`;
