-- Gap-filled FX rates.
--
-- fx_rates_master has rows only for dates the ECB published (business
-- days). Orders placed on weekends or holidays need a rate too — we
-- forward-fill from the most recent published rate.
--
-- One row per (rate_date, currency) for every date from the earliest
-- published rate up to today, including an AUD self-row with
-- rate_to_aud = 1.0.
--
-- This view is what v_orders and v_order_items join against. Never
-- query fx_rates_master directly for currency conversion.

CREATE OR REPLACE VIEW `peppermayo.v_fx_rates_filled`
(
  rate_date OPTIONS(description="Calendar DATE. Dense from MIN(fx_rates_master.rate_date) to CURRENT_DATE()."),
  currency OPTIONS(description="ISO-4217 code (AUD/USD/GBP/CAD/EUR). AUD carries rate_to_aud = 1.0 for uniform joins."),
  rate_to_aud OPTIONS(description="Multiplier from `currency` to AUD. Forward-filled across weekends/holidays. May be NULL only for dates before the earliest published rate for that currency.")
)
OPTIONS(description="Gap-filled FX rates. ALWAYS join this view (not fx_rates_master) for currency conversion so weekend/holiday orders are covered.")
AS
WITH bounds AS (
  SELECT MIN(rate_date) AS min_date FROM `peppermayo.fx_rates_master`
),
calendar AS (
  SELECT d AS rate_date
  FROM bounds, UNNEST(GENERATE_DATE_ARRAY(bounds.min_date, CURRENT_DATE())) AS d
),
currencies AS (
  SELECT DISTINCT currency FROM `peppermayo.fx_rates_master`
),
grid AS (
  SELECT c.rate_date, cur.currency
  FROM calendar c CROSS JOIN currencies cur
)
SELECT
  g.rate_date,
  g.currency,
  LAST_VALUE(f.rate_to_aud IGNORE NULLS) OVER (
    PARTITION BY g.currency
    ORDER BY g.rate_date
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS rate_to_aud
FROM grid g
LEFT JOIN `peppermayo.fx_rates_master` f
  ON f.rate_date = g.rate_date AND f.currency = g.currency;
