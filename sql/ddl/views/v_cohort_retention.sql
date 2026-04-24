-- v_cohort_retention — acquisition cohort × months-since-acquisition.
--
-- Grain: (cohort_month, months_since_acquisition, cohort_region).
-- Measures how a cohort's spend evolves over time, region-scoped to
-- the acquisition region (last_order_region can differ).
--
-- `cohort_size` is the total number of customers in the cohort (same
-- across every row for that cohort).
-- `retained_customers` is the subset of the cohort that placed an
-- order in the given months_since_acquisition bucket.
-- `retention_pct` = retained_customers / cohort_size.

CREATE OR REPLACE VIEW `peppermayo.v_cohort_retention`
(
  cohort_region OPTIONS(description="Acquisition region (first_order_region). Customers who later bought in a different region are still attributed to their acquisition region here."),
  cohort_month OPTIONS(description="Sydney-local month of the customer's first non-cancelled order."),
  months_since_acquisition OPTIONS(description="Integer months between the order and the cohort_month. 0 = same month as acquisition."),
  cohort_size OPTIONS(description="Total customers in the cohort. Constant across every row for the cohort."),
  retained_customers OPTIONS(description="Distinct customers from the cohort who placed a non-cancelled order in this months_since_acquisition bucket."),
  retention_pct OPTIONS(description="retained_customers / cohort_size."),
  cohort_revenue_aud OPTIONS(description="SUM(total_price_aud) from the cohort in this months_since_acquisition bucket. GROSS (pre-refund)."),
  revenue_per_cohort_member_aud OPTIONS(description="cohort_revenue_aud / cohort_size.")
)
OPTIONS(description="Acquisition cohort retention. Grain: (cohort_region, cohort_month, months_since_acquisition). ALREADY excludes cancelled orders.")
AS
WITH cohort AS (
  SELECT
    customer_id,
    first_order_region AS cohort_region,
    acquisition_cohort_month_sydney AS cohort_month
  FROM `peppermayo.v_customers`
  WHERE first_order_at IS NOT NULL
),
cohort_size AS (
  SELECT cohort_region, cohort_month, COUNT(*) AS cohort_size
  FROM cohort
  GROUP BY cohort_region, cohort_month
),
activity AS (
  SELECT
    c.cohort_region,
    c.cohort_month,
    DATE_DIFF(o.created_month_sydney, c.cohort_month, MONTH) AS months_since_acquisition,
    o.customer_id,
    o.total_price_aud
  FROM cohort c
  JOIN `peppermayo.v_orders` o USING (customer_id)
  WHERE NOT o.is_cancelled
)
SELECT
  a.cohort_region,
  a.cohort_month,
  a.months_since_acquisition,
  s.cohort_size,
  COUNT(DISTINCT a.customer_id) AS retained_customers,
  SAFE_DIVIDE(COUNT(DISTINCT a.customer_id), s.cohort_size) AS retention_pct,
  SUM(a.total_price_aud) AS cohort_revenue_aud,
  SAFE_DIVIDE(SUM(a.total_price_aud), s.cohort_size) AS revenue_per_cohort_member_aud
FROM activity a
JOIN cohort_size s USING (cohort_region, cohort_month)
GROUP BY a.cohort_region, a.cohort_month, a.months_since_acquisition, s.cohort_size;
