-- FX rates master table.
--
-- One row per (rate_date, currency) with the multiplier to convert
-- a native-currency amount into AUD. Populated daily by the same
-- Lambda that syncs Shopify orders, with AUD as the ECB base via
-- Frankfurter (https://api.frankfurter.dev) — the ECB reference
-- rates are the same source most accounting systems use, so values
-- reconcile with Xero/NetSuite.
--
-- Gaps (weekends, public holidays) are filled forward by the
-- `v_fx_rates_filled` view, which is what the v_orders /
-- v_order_items views actually join against.
--
-- Convention: to convert a native amount to AUD, multiply by
--   rate_to_aud. The row where currency = 'AUD' always has
--   rate_to_aud = 1.0, so the same join works regardless of the
--   order's currency.
--
-- To convert AUD to any other currency X, divide by X's rate_to_aud
-- (equivalently: 1 / rate_to_aud is the AUD -> X multiplier).

CREATE TABLE `peppermayo.fx_rates_master` (
  rate_date DATE NOT NULL OPTIONS(description="The date these rates apply to (the date on which ECB published them, UTC)."),
  currency STRING NOT NULL OPTIONS(description="ISO-4217 code of the native currency. One of: AUD, USD, GBP, CAD, EUR."),
  rate_to_aud FLOAT64 NOT NULL OPTIONS(description="Multiplier to convert a native amount to AUD. 1.0 for AUD itself. Example: a USD row with rate_to_aud = 1.55 means 100 USD = 155 AUD."),
  source STRING OPTIONS(description="Upstream source identifier. Always 'frankfurter/ecb' for Peppermayo.")
)
PARTITION BY rate_date
CLUSTER BY currency
OPTIONS(
  description="Daily foreign-exchange rates (AUD-based) sourced from the European Central Bank via Frankfurter. Use v_fx_rates_filled for gap-filled lookups."
);
