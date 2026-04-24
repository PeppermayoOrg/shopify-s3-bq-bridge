-- Upsert daily FX staging into fx_rates_master.
--
-- Primary key is (rate_date, currency). ECB rates for a given date are
-- immutable once published, so UPDATE is effectively a no-op — we include
-- it only to make re-runs safe if Frankfurter ever corrects a figure.
--
-- The historical FX backfill writes the same CSV shape into the same
-- staging table, so this one MERGE covers both daily and backfill loads.
MERGE `peppermayo.fx_rates_master` T
USING `peppermayo.staging_fx_rates` S
ON T.rate_date = S.rate_date AND T.currency = S.currency
WHEN MATCHED THEN
  UPDATE SET rate_to_aud = S.rate_to_aud, source = S.source
WHEN NOT MATCHED THEN
  INSERT (rate_date, currency, rate_to_aud, source)
  VALUES (S.rate_date, S.currency, S.rate_to_aud, S.source);
