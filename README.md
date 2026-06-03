# shopify-s3-bq-bridge

Daily sync from Peppermayo's five Shopify storefronts (AU, US, UK, CA, EU) and Refundid to a BigQuery warehouse, via S3.

See [architecture.md](architecture.md) for the full design.

## Layout

```text
src/lambda/index.js                     Daily (orders+fx) and weekly (products) Lambda
src/shared/utils.js                     Shared Shopify/FX → CSV mapping, retry, pagination
src/shared/refundid.js                  Refundid API client and daily extraction
scripts/historical_sync.js              One-off backfill (orders, fx, products, all) + targeted gap-fill
scripts/historical_refundid.js          One-off backfill for Refundid returns
scripts/verify_data.js                  Data integrity verifier (counts, revenue, spotcheck, diff) — see VERIFY.md
scripts/deploy_scheduled_queries.sh     Push sql/dml/*.sql into BigQuery Scheduled Queries
scripts/deploy_views.sh                 Push sql/ddl/views/*.sql into BigQuery views
sql/ddl/                                Master + staging table definitions (orders, items, refunds,
                                        fulfillments, products, customers, fx, refundid)
sql/ddl/views/                          Semantic-layer views (v_orders, v_order_items, v_refunds,
                                        v_fulfillments, v_products, v_product_performance, …)
sql/dml/                                MERGE / REFRESH statements run by BigQuery Scheduled Queries
```

## Prerequisites

- Node.js 24+
- AWS account with:
  - S3 bucket `peppermayo-shopify-orders`
  - SSM parameters at `/shopify/peppermayo-<region>/token` (SecureString) for each of `au`, `us`, `uk`, `ca`, `eu`
  - Lambda execution role with `ssm:GetParameter` on those parameters and `s3:PutObject` on the bucket
- GCP project with BigQuery dataset `peppermayo` in `australia-southeast1`
- BigQuery Data Transfer Service configured against the S3 bucket — **nine** configs:
  - **Shopify Daily Sync - Orders (Staging)**           → `daily/orders/*.csv`            → `staging_orders`
  - **Shopify Daily Sync - Items (Staging)**            → `daily/items/*.csv`             → `staging_order_items`
  - **Shopify Daily Sync - Refunds (Staging)**          → `daily/refunds/*.csv`           → `staging_refunds`
  - **Shopify Daily Sync - Refund Items (Staging)**     → `daily/refund_items/*.csv`      → `staging_refund_line_items`
  - **Shopify Daily Sync - Fulfillments (Staging)**     → `daily/fulfillments/*.csv`      → `staging_fulfillments`
  - **Shopify Daily Sync - Fulfillment Items (Staging)** → `daily/fulfillment_items/*.csv` → `staging_fulfillment_line_items`
  - **Shopify Daily Sync - FX (Staging)**               → `daily/fx/*.csv`                → `staging_fx_rates`
  - **Shopify Weekly Sync - Products (Staging)**        → `weekly/products/*.csv`         → `staging_products`
  - **Shopify Weekly Sync - Variants (Staging)**        → `weekly/product_variants/*.csv` → `staging_product_variants`
- Nine BigQuery Scheduled Queries covering the seven MERGEs plus the two refreshes (see [BigQuery Scheduled Queries to configure](#bigquery-scheduled-queries-to-configure) below)
- Two EventBridge rules on the Lambda: daily `cron(0 15 * * ? *)` with no payload, and weekly `cron(0 14 ? * MON *)` with payload `{"mode":"products"}`

## Install

```sh
npm install
```

## Deploy the Lambda

```sh
npm run build   # produces lambda.zip
```

Upload `lambda.zip` to the Lambda console.

Handler: `src/lambda/index.handler` (the zip preserves the `src/lambda/` path).

Runtime: Node.js 24.

Timeout: 15 minutes (maximum).

EventBridge schedule: `cron(0 15 * * ? *)` (15:00 UTC — 01:00 AEST / 02:00 AEDT Sydney, next day).

Required environment variables: none.

Optional: `S3_BUCKET` to override the default bucket name.

## Create the BigQuery tables

Run once per environment:

```sh
bq query --use_legacy_sql=false < sql/ddl/create_master_tables.sql
bq query --use_legacy_sql=false < sql/ddl/create_staging_tables.sql
bq query --use_legacy_sql=false < sql/ddl/create_fx_tables.sql
bq query --use_legacy_sql=false < sql/ddl/create_staging_fx_tables.sql
bq query --use_legacy_sql=false < sql/ddl/create_refunds_tables.sql
bq query --use_legacy_sql=false < sql/ddl/create_staging_refunds_tables.sql
bq query --use_legacy_sql=false < sql/ddl/create_fulfillments_tables.sql
bq query --use_legacy_sql=false < sql/ddl/create_staging_fulfillments_tables.sql
bq query --use_legacy_sql=false < sql/ddl/create_staging_products_tables.sql
```

(`products_master` and `product_variants_master` are not pre-created — `refresh_products_master.sql` issues `CREATE OR REPLACE TABLE` on every run.)

> **Note on schema changes.** BigQuery CSV loads bind columns by **ordinal
> position** — the header row is only consumed via `skip_leading_rows`
> and column names are never matched. This has two strict consequences:
>
> 1. **Never use `ALTER TABLE ADD COLUMN` on a CSV-loaded staging or master
>    table.** `ADD COLUMN` appends at the end, but the CSV will still put
>    the new column at its repo-declared position — loads will silently
>    mis-assign every column after the insertion point (and eventually
>    fail when a type mismatch surfaces, as on 2026-04-23 with
>    `source_name`).
> 2. **Column order in staging DDL must match the `_HEADER` arrays in
>    [src/shared/utils.js](src/shared/utils.js) exactly.** A pre-build
>    guard (`npm run verify:schema`, wired into `npm run build`)
>    enforces this. Do not bypass it.
> 3. **Before and after any schema-changing deploy, run
>    `npm run verify:schema:live`.** This extends the static check by
>    shelling out to `bq show` for every staging + master table and
>    diffing the live column order against the repo DDL. Catches drift
>    that originated outside this repo (e.g. a console `ALTER TABLE ADD
>    COLUMN` — which is how the 2026-04-23 incident happened). Requires
>    `bq` CLI auth. Override the dataset with `BQ_DATASET=...` env var
>    (default: `peppermayo`).
>
> When the master-table shape changes: write a migration under
> `sql/migrations/` that rebuilds staging (`DROP` + `CREATE`) and master
> (`CREATE OR REPLACE TABLE ... AS SELECT`, preserving data) with the
> columns in the correct order. Deploy the migration **before** the new
> Lambda. The daily pipeline will repopulate the last 26 hours on its
> next run; a full historical backfill is only needed when a newly added
> column requires historical values (not auto-populatable via MERGE from
> future Shopify `updated_at` bumps).

## Deploy the semantic-layer views

The `v_*` views in [sql/ddl/views/](sql/ddl/views/) are the preferred
querying surface for BI and for the LLM. Deploy them after the master /
staging / fx tables exist:

```sh
npm run deploy:views           # deploy all views in dependency order
npm run deploy:views v_orders  # deploy a single view
```

The script uses `bq query` (part of `gcloud`) and issues each file as
`CREATE OR REPLACE VIEW`, so it is safe to re-run. Dependency order is
hard-coded in the script: `v_fx_rates_filled` \u2192 `v_orders` \u2192
`v_order_items` \u2192 `v_customers` \u2192 `v_daily_sales` \u2192 `v_monthly_sales`
\u2192 `v_discount_code_performance` \u2192 `v_cohort_retention` \u2192 `v_refunds`
\u2192 `v_fulfillments` \u2192 `v_products` \u2192 `v_product_variants` \u2192
`v_product_performance`.

## BigQuery Scheduled Queries to configure

Create these nine scheduled queries in the BigQuery console once per
environment. Each one has its SQL **synced from this repo** via
`npm run deploy:sql` — paste any non-empty SQL at creation time; the
actual body is pushed immediately afterwards.

| Name | Schedule (UTC) | SQL file |
| --- | --- | --- |
| Daily Shopify Merge - Orders | `every day 16:00` | `sql/dml/merge_orders.sql` |
| Daily Shopify Merge - Items | `every day 16:00` | `sql/dml/merge_items.sql` |
| Daily FX Merge | `every day 16:05` | `sql/dml/merge_fx_rates.sql` |
| Daily Shopify Merge - Refunds | `every day 16:10` | `sql/dml/merge_refunds.sql` |
| Daily Shopify Merge - Refund Items | `every day 16:10` | `sql/dml/merge_refund_line_items.sql` |
| Daily Shopify Merge - Fulfillments | `every day 16:10` | `sql/dml/merge_fulfillments.sql` |
| Daily Shopify Merge - Fulfillment Items | `every day 16:10` | `sql/dml/merge_fulfillment_line_items.sql` |
| Daily Customers Refresh | `every day 16:15` | `sql/dml/refresh_customers_master.sql` |
| Weekly Products Refresh | `every monday 14:45` | `sql/dml/refresh_products_master.sql` |

All queries run in `australia-southeast1`. Ordering constraints:

- Orders / Items / Refunds / Refund Items / Fulfillments / Fulfillment Items / FX must all complete **before** **Daily Customers Refresh** — it reads `v_orders` / `v_order_items`, which depend on refund and fulfilment aggregates.
- Refunds merge must complete **before** Refund Items; Fulfillments merge must complete **before** Fulfillment Items (the child merges join to the parent master). Having them all scheduled at 16:10 is fine because BigQuery orders scheduled-query runs by creation time and we create them in this order; if in doubt, stagger by 1 minute.

After each query exists, copy its transferConfig resource path
(`projects/.../locations/australia-southeast1/transferConfigs/...`) from
the **Configuration** tab and paste it into
[scripts/deploy_scheduled_queries.sh](scripts/deploy_scheduled_queries.sh):
`ORDERS_CFG`, `ITEMS_CFG`, `FX_CFG`, `CUSTOMERS_CFG`, `REFUNDS_CFG`,
`REFUND_ITEMS_CFG`, `FULFILLMENTS_CFG`, `FULFILLMENT_ITEMS_CFG`,
`PRODUCTS_CFG` (either inline or exported as env vars).

## Deploy the MERGE / REFRESH SQL to BigQuery

The MERGE and REFRESH statements in [sql/dml/](sql/dml) are the source of
truth. BigQuery stores each query's SQL inside the scheduled-query
resource itself, so after editing the `.sql` files you must push the new
bodies up:

```sh
npm run deploy:sql                        # push all nine
npm run deploy:sql -- orders              # orders only
npm run deploy:sql -- items               # items only
npm run deploy:sql -- fx                  # fx merge only
npm run deploy:sql -- customers           # customers refresh only
npm run deploy:sql -- refunds             # refunds merge only
npm run deploy:sql -- refund_items        # refund items merge only
npm run deploy:sql -- fulfillments        # fulfillments merge only
npm run deploy:sql -- fulfillment_items   # fulfillment items merge only
npm run deploy:sql -- products            # weekly products refresh only
```

Requires the `bq` CLI (part of `gcloud`) authenticated against the project
that owns the configs, and `jq`. The script only patches the `query` param
of each transferConfig; schedule, destination table, credentials and run
history are untouched, so it is safe to run against a live pipeline. The
next scheduled run will pick up the new SQL.

Verify in the BigQuery console: **Scheduled queries** → open each query and
confirm the SQL body matches the file and that **Next run** is still in the
future.

## Run the historical backfill

Requires local AWS credentials (for S3 writes) and a `.env` file with
`SHOPIFY_TOKEN_<REGION>` values — see [.env.example](.env.example).
Infrastructure credentials that are not consumed by code in this repo (e.g.
the AWS IAM user used by the BigQuery Data Transfer Service) are documented
separately in [INFRA.md](INFRA.md).

Start dates per region are configured directly in
[scripts/historical_sync.js](scripts/historical_sync.js) via the `START_DATES`
object near the bottom of the file. Edit it to set each region's start date
(or comment a region out to skip it), then run:

```sh
npm run backfill              # orders only (default) — writes all 6 order-side CSVs
npm run backfill -- fx        # fx rates only
npm run backfill -- products  # full product catalog for all regions (one-shot)
npm run backfill -- all       # orders + fx + products
```

FX backfill range is controlled by `FX_START` / `FX_END` constants near
the bottom of [scripts/historical_sync.js](scripts/historical_sync.js).
Frankfurter has full history back to 1999 (ECB reference rates), so set
`FX_START` to match or predate the earliest order `created_at` across all
regions.

The script walks forward one month at a time per region and writes to
`s3://peppermayo-shopify-orders/historical/{orders,items,refunds,refund_items,fulfillments,fulfillment_items}/`
and (for the `fx` / `all` modes) `.../historical/fx/fx_historical_<start>_to_<end>.csv`.
The `products` mode writes directly to `weekly/products/` and
`weekly/product_variants/` — there's no separate historical prefix for
products since only the current catalog state is relevant. All temporary CSV
files go under `os.tmpdir()`; nothing lands in the repo root. The daily DTS
configs only watch `daily/` — the historical prefix is **not** picked up
automatically. Historical data is loaded via the same
`staging_*` → `MERGE` path the daily pipeline uses, which means it is safe
to run alongside the live daily pipeline: the merge's
`S.updated_at > T.updated_at` guard prevents historical rows from clobbering
fresher daily data.

After the backfill script completes:

1. BigQuery → **Data Transfers** → **Create Transfer**, create seven on-demand
   (run-once) transfers — one per order-side CSV type, plus FX:

   **Historical Orders → Staging**
   - Source: Amazon S3
   - Schedule: On-demand
   - Destination table: `staging_orders`
   - Amazon S3 URI: `s3://peppermayo-shopify-orders/historical/orders/*.csv`
   - Write preference: `WRITE_TRUNCATE`
   - CSV: skip 1 header row, allow quoted newlines, ignore unknown values

   **Historical Items → Staging**
   - Destination table: `staging_order_items`
   - Amazon S3 URI: `s3://peppermayo-shopify-orders/historical/items/*.csv`
   - Same settings as above

   **Historical Refunds → Staging**
   - Destination table: `staging_refunds`
   - Amazon S3 URI: `s3://peppermayo-shopify-orders/historical/refunds/*.csv`

   **Historical Refund Items → Staging**
   - Destination table: `staging_refund_line_items`
   - Amazon S3 URI: `s3://peppermayo-shopify-orders/historical/refund_items/*.csv`

   **Historical Fulfillments → Staging**
   - Destination table: `staging_fulfillments`
   - Amazon S3 URI: `s3://peppermayo-shopify-orders/historical/fulfillments/*.csv`

   **Historical Fulfillment Items → Staging**
   - Destination table: `staging_fulfillment_line_items`
   - Amazon S3 URI: `s3://peppermayo-shopify-orders/historical/fulfillment_items/*.csv`

   **Historical FX → Staging**
   - Destination table: `staging_fx_rates`
   - Amazon S3 URI: `s3://peppermayo-shopify-orders/historical/fx/*.csv`
   - Same settings as above

2. Run the steps below **in one sitting**, in a window that does not
   cross the daily 15:30 UTC DTS run (01:30 AEST / 02:30 AEDT Sydney — the
   daily DTS also `WRITE_TRUNCATE`s the staging tables and would wipe your
   historical load mid-flight). The safest window is shortly after 16:00 UTC
   (02:00 AEST / 03:00 AEDT Sydney) — the daily merges have just finished
   and you have nearly 23 hours before the next daily DTS fires.

   1. Run the historical **Orders** transfer → `staging_orders`.
   2. **Daily Shopify Merge - Orders** → **Run now**. Wait.
   3. Run the historical **Items** transfer → `staging_order_items`.
   4. **Daily Shopify Merge - Items** → **Run now**.
   5. Run the historical **Refunds** transfer → `staging_refunds`.
   6. **Daily Shopify Merge - Refunds** → **Run now**.
   7. Run the historical **Refund Items** transfer → `staging_refund_line_items`.
   8. **Daily Shopify Merge - Refund Items** → **Run now**.
   9. Run the historical **Fulfillments** transfer → `staging_fulfillments`.
   10. **Daily Shopify Merge - Fulfillments** → **Run now**.
   11. Run the historical **Fulfillment Items** transfer → `staging_fulfillment_line_items`.
   12. **Daily Shopify Merge - Fulfillment Items** → **Run now**.
   13. Run the historical **FX** transfer → `staging_fx_rates`.
   14. **Daily FX Merge** → **Run now**.
   15. **Daily Customers Refresh** → **Run now** to materialise `customers_master`
       over the full history (refund-adjusted).

Products are loaded by the weekly pipeline — once `npm run backfill -- products`
has uploaded CSVs to `weekly/products/` and `weekly/product_variants/`, run the
two weekly DTS transfers on-demand, then **Weekly Products Refresh** → **Run now**.

The daily pipeline keeps running through all of this. Any mutations on
historical orders captured by recent daily runs stay in master — the
MERGE's `updated_at` guard ignores older historical rows for those
order_ids.

If the backfill script itself is interrupted, update `START_DATES` to the
last month that was successfully uploaded and re-run — re-uploading an
already-written month to S3 is safe; the one-shot historical transfers
haven't run yet.

Note: the backfill script writes CSVs to `os.tmpdir()` (a per-run scratch
directory). Nothing lands in the repo root.

## Daily flow

All schedules are configured in UTC; Sydney local times shown for
convenience (AEDT runs Oct–Apr, AEST runs Apr–Oct).

1. 15:00 UTC (01:00 AEST / 02:00 AEDT, next day) — Lambda writes six CSVs per region under `daily/{orders,items,refunds,refund_items,fulfillments,fulfillment_items}/` plus `daily/fx/fx_YYYY-MM-DD.csv`.
2. 15:30 UTC — seven BigQuery Data Transfers load those CSVs into the seven `staging_*` tables (`WRITE_TRUNCATE`).
3. 16:00 UTC — Scheduled Queries run `merge_orders.sql` then `merge_items.sql`.
4. 16:05 UTC — `merge_fx_rates.sql` upserts the day's FX snapshot into `fx_rates_master`.
5. 16:10 UTC — `merge_refunds.sql`, `merge_refund_line_items.sql`, `merge_fulfillments.sql`, `merge_fulfillment_line_items.sql` run.
6. 16:15 UTC — `refresh_customers_master.sql` rebuilds `customers_master` from the freshly-updated `v_orders` / `v_order_items` (refund-adjusted).

Weekly (Mondays):

1. 14:00 UTC — Lambda invoked with `{"mode":"products"}` pulls the catalog per region into `weekly/products/` and `weekly/product_variants/`.
2. 14:30 UTC — two weekly Data Transfers load them into `staging_products` / `staging_product_variants`.
3. 14:45 UTC — **Weekly Products Refresh** rebuilds `products_master` and `product_variants_master` via `CREATE OR REPLACE TABLE`.

## Verifying data integrity

See [VERIFY.md](VERIFY.md) for step-by-step instructions on auditing the
warehouse against Shopify (counts, revenue, spotcheck, diff modes), plus
recovery procedures for any gaps surfaced by the checks. Run a
quick-audit (`npm run verify:counts` + `npm run verify:spotcheck -- 50`)
after every backfill or schema change, and the full-audit recipe
quarterly.
