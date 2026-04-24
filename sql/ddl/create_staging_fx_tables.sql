-- Staging for daily FX snapshots. Same shape as the master table,
-- everything nullable, no partitioning or clustering. WRITE_TRUNCATEd
-- every run.

CREATE TABLE `peppermayo.staging_fx_rates` (
  rate_date DATE,
  currency STRING,
  rate_to_aud FLOAT64,
  source STRING
);
