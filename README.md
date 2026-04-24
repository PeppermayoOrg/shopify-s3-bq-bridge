# shopify-s3-bq-bridge

Daily sync from Peppermayo's five Shopify storefronts (AU, US, UK, CA, EU) to a BigQuery warehouse, via S3.

See [architecture.md](architecture.md) for the full design.

## Layout

```text
src/lambda/index.js                     Daily extraction Lambda
src/shared/utils.js                     Shared Shopify → CSV row mapping, retry, pagination
scripts/historical_sync.js              One-off historical backfill (run locally)
scripts/deploy_scheduled_queries.sh     Push sql/dml/*.sql into BigQuery Scheduled Queries
sql/ddl/                                Master + staging table definitions
sql/dml/                                MERGE statements run by BigQuery Scheduled Queries
```

## Prerequisites

- Node.js 20+
- AWS account with:
  - S3 bucket `peppermayo-shopify-orders`
  - SSM parameters at `/shopify/peppermayo-<region>/token` (SecureString) for each of `au`, `us`, `uk`, `ca`, `eu`
  - Lambda execution role with `ssm:GetParameter` on those parameters and `s3:PutObject` on the bucket
- GCP project with BigQuery dataset `peppermayo` in `australia-southeast1`
- BigQuery Data Transfer Service configured against the S3 bucket (two configs: **Shopify Daily Sync - Orders (Staging)** → `daily/orders/*.csv`; **Shopify Daily Sync - Items (Staging)** → `daily/items/*.csv`)
- Two BigQuery Scheduled Queries pointing at `sql/dml/merge_orders.sql` and `sql/dml/merge_items.sql`

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

Runtime: Node.js 20.

Timeout: 15 minutes (maximum).

EventBridge schedule: `cron(0 15 * * ? *)` (15:00 UTC — 01:00 AEST / 02:00 AEDT Sydney, next day).

Required environment variables: none.

Optional: `S3_BUCKET` to override the default bucket name.

## Create the BigQuery tables

Run once per environment:

```sh
bq query --use_legacy_sql=false < sql/ddl/create_master_tables.sql
bq query --use_legacy_sql=false < sql/ddl/create_staging_tables.sql
```

## Deploy the MERGE SQL to BigQuery

The MERGE statements in [sql/dml/](sql/dml) are the source of truth. They are
executed by two BigQuery Scheduled Queries ("Daily Shopify Merge - Orders"
and "Daily Shopify Merge - Items"). BigQuery stores each query's SQL inside
the scheduled-query resource itself, so after editing the `.sql` files you
must push the new bodies up:

```sh
npm run deploy:sql           # push both
npm run deploy:sql -- orders # orders only
npm run deploy:sql -- items  # items only
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
npm run backfill
```

The script walks forward one month at a time per region and writes to
`s3://peppermayo-shopify-orders/historical/orders/` and `.../historical/items/`.
The daily DTS configs only watch `daily/` — the historical prefix is **not**
picked up automatically. Historical data is loaded via the same
`staging_*` → `MERGE` path the daily pipeline uses, which means it is safe
to run alongside the live daily pipeline: the merge's
`S.updated_at > T.updated_at` guard prevents historical rows from clobbering
fresher daily data.

After the backfill script completes:

1. BigQuery → **Data Transfers** → **Create Transfer**, create two on-demand
   (run-once) transfers:

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

2. Run the four steps below **in one sitting**, in a window that does not
   cross the daily 15:30 UTC DTS run (01:30 AEST / 02:30 AEDT Sydney — the
   daily DTS also `WRITE_TRUNCATE`s the staging tables and would wipe your
   historical load mid-flight). The safest window is shortly after 16:00 UTC
   (02:00 AEST / 03:00 AEDT Sydney) — the daily merges have just finished
   and you have nearly 23 hours before the next daily DTS fires.

   1. Run the historical **Orders** transfer → `staging_orders`.
   2. BigQuery → **Scheduled queries** → **Daily Shopify Merge - Orders** →
      **Run now**. Wait for it to finish.
   3. Run the historical **Items** transfer → `staging_order_items`.
   4. **Daily Shopify Merge - Items** → **Run now**.

The daily pipeline keeps running through all of this. Any mutations on
historical orders captured by recent daily runs stay in master — the
MERGE's `updated_at` guard ignores older historical rows for those
order_ids.

If the backfill script itself is interrupted, update `START_DATES` to the
last month that was successfully uploaded and re-run — re-uploading an
already-written month to S3 is safe; the one-shot historical transfers
haven't run yet.

Note: the backfill script writes CSVs to the current working directory (not
`/tmp`). Run it from a scratch folder if you don't want stray files in the
repo root.

## Daily flow

All schedules are configured in UTC; Sydney local times shown for
convenience (AEDT runs Oct–Apr, AEST runs Apr–Oct).

1. 15:00 UTC (01:00 AEST / 02:00 AEDT, next day) — Lambda writes `daily/orders/<region>_orders_YYYY-MM-DD.csv` and `daily/items/<region>_items_YYYY-MM-DD.csv` to S3.
2. 15:30 UTC (01:30 AEST / 02:30 AEDT) — BigQuery Data Transfer loads those CSVs into `staging_orders` / `staging_order_items` (`WRITE_TRUNCATE`).
3. 16:00 UTC (02:00 AEST / 03:00 AEDT) — Scheduled Queries run `merge_orders.sql` then `merge_items.sql`, upserting into the master tables.
