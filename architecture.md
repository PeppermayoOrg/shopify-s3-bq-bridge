# Peppermayo E-commerce Data Pipeline — Architecture

## 1. Overview

This pipeline synchronises order data from Peppermayo's five Shopify storefronts (AU, US, UK, CA, EU) into a single Google BigQuery warehouse. Nested Shopify JSON is flattened into a relational schema, PII is stripped at the extraction layer, and daily upserts keep the warehouse consistent with Shopify as orders move through their lifecycle.

The resulting warehouse is the source of truth for BI reporting and for LLM-assisted querying via Claude Cowork.

## 2. High-level Architecture

An ETL pipeline split across AWS (extract, stage as files) and GCP (load, transform, serve).

- **Extract** — Node.js Lambda calls the Shopify Admin REST API (`2026-01`) per storefront.
- **Transform** — Order JSON is flattened into two flat tables (orders, line items). PII fields are dropped. Timestamps are kept as ISO 8601 strings; BigQuery parses them on load.
- **Stage (S3)** — CSVs are written to `s3://peppermayo-shopify-orders/daily/` for the daily run and `historical/` for the one-off backfill.
- **Load (BigQuery)** — BigQuery Data Transfer Service pulls the latest daily CSVs into staging tables with `WRITE_TRUNCATE`.
- **Upsert (BigQuery)** — Scheduled Queries run `MERGE` statements from staging into the master tables, handling inserts for new orders and updates for mutations (refunds, cancellations, fulfilment changes).

## 3. Infrastructure

### 3.1 AWS

| Component | Purpose |
| --- | --- |
| Systems Manager Parameter Store | Stores the Shopify Admin API token for each store as a `SecureString`. Path: `/shopify/peppermayo-<region>/token`. |
| Lambda (Node.js 20) | Runs the daily extraction. Reads the 26-hour rolling window of `updated_at`, writes CSVs to `/tmp`, uploads to S3. Processes sequentially (one region at a time) to prevent `/tmp` storage exhaustion and memory spikes during peak order volumes, ensuring one massive storefront can't crash the container and disrupt the rest. |
| EventBridge | Triggers the Lambda daily at 15:00 UTC (01:00 AEST / 02:00 AEDT Sydney, next day). Cron expression: `cron(0 15 * * ? *)`. |
| S3 (`peppermayo-shopify-orders`) | Raw data lake. Retained for disaster recovery and reprocessing. Bucket versioning and default server-side encryption (AES256) are enabled. |
| IAM user for BigQuery DTS | Read-only access scoped to the two S3 prefixes used by Data Transfer. |

The Lambda uses a 26-hour window (not 24) so that a delayed or retried run still picks up everything that landed during the gap. Orders touched twice in overlapping windows are deduped by the `MERGE`.

### 3.2 GCP

| Component | Purpose |
| --- | --- |
| BigQuery dataset `peppermayo` | Located in `australia-southeast1` (Sydney). Tables live here. |
| BigQuery Data Transfer Service | Two Amazon S3 transfers, both scheduled 15:30 UTC (01:30 AEST / 02:30 AEDT Sydney): **Shopify Daily Sync - Orders (Staging)** pulls `s3://peppermayo-shopify-orders/daily/orders/*.csv` into `staging_orders`, and **Shopify Daily Sync - Items (Staging)** pulls `s3://peppermayo-shopify-orders/daily/items/*.csv` into `staging_order_items`. Both use `WRITE_TRUNCATE`. Files under `historical/` are **not** watched by any DTS and must be loaded manually once the backfill completes (see §5). |
| BigQuery Scheduled Queries | Run `sql/dml/merge_orders.sql` then `sql/dml/merge_items.sql` at 16:00 UTC (02:00 AEST / 03:00 AEDT Sydney). SQL bodies are synced from this repo via `scripts/deploy_scheduled_queries.sh` (`npm run deploy:sql`); BigQuery stores the query text inside the scheduled-query resource itself, so that script is the only way in-repo SQL makes it into BigQuery. |

## 4. Data Model

Two tables, joined on `order_id`. Nested arrays are avoided so the schema is easy for analysts (and LLMs) to reason about.

### 4.1 `peppermayo.orders_master`

Order-level financials and state.

- **Partitioning:** `DATE(created_at)` — keeps time-bound queries cheap (e.g. "sales this month").
- **Clustering:** `store_region`, `financial_status` — accelerates the two most common filters.
- **PII policy:** `customer_id` is kept for cohort analysis. Name, email, phone, and street address are never written. Shipping country/region is available via `store_region` at a coarser grain.

### 4.2 `peppermayo.order_items_master`

One row per line item.

- **Clustering:** `order_id`, `sku` — accelerates joins back to orders and product-level aggregations.
- **Transformation:** Shopify's free-text `variant_title` (formatted strictly as "Colour / Size") is parsed at extraction time into separate `colour` and `size` columns. The parser lives in both the Lambda and the historical script and must stay in sync.

See [sql/ddl/create_master_tables.sql](sql/ddl/create_master_tables.sql) and [sql/ddl/create_staging_tables.sql](sql/ddl/create_staging_tables.sql) for the full schema.

## 5. Idempotency and Upsert Logic

Shopify orders are mutable — an order created today may be refunded, edited, or cancelled tomorrow. The pipeline handles this through a staging-to-master `MERGE`.

- **Staging is disposable.** `staging_orders` and `staging_order_items` are truncated and rewritten every day and only ever contain the last ~26 hours of deltas.
- **Master is append-and-update.** For orders, `MERGE` inserts new `order_id`s and updates existing ones, guarded by `S.updated_at > T.updated_at` so an out-of-order run can't overwrite newer data. All mutable fields refresh on match — statuses, timestamps, totals, tags, and discount codes — so refunds and order edits propagate. For line items, the merge filters staging to only those rows whose parent order in staging matches the parent order now in master (same `updated_at`): that equality is true exactly when `merge_orders.sql` has just inserted or updated the order from this staging snapshot. Orders where the orders-merge rejected staging (because master had fresher data from the daily pipeline) are skipped here too, so the historical load can't clobber fresher items. Matched rows refresh their mutable fields (`quantity`, `price`, `sku`, `name`, `size`, `colour`).
- **Backfill.** `scripts/historical_sync.js` writes monthly CSVs to `s3://peppermayo-shopify-orders/historical/orders/` and `.../historical/items/`. The daily DTS configs do **not** watch this prefix. Historical data is loaded via the same `staging_*` → `MERGE` path the daily pipeline uses; this reuses the MERGE's `S.updated_at > T.updated_at` guard so it is safe to run alongside the live daily pipeline without clobbering fresher data.

  One-time historical load, run after the backfill script finishes:

  1. In BigQuery → Data Transfers → **Create Transfer**, create two on-demand (run-once) transfers:

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

  2. Run the full sequence in one sitting, in a window that does **not** cross the daily 15:30 UTC DTS run (01:30 AEST / 02:30 AEDT Sydney; the daily DTS also `WRITE_TRUNCATE`s the staging tables). The safest window is shortly after 16:00 UTC (02:00 AEST / 03:00 AEDT Sydney), which gives nearly 23 hours of headroom:

     1. Run the historical Orders transfer → `staging_orders`.
     2. BigQuery → Scheduled queries → **Daily Shopify Merge - Orders** → **Run now**.
     3. Run the historical Items transfer → `staging_order_items`.
     4. BigQuery → Scheduled queries → **Daily Shopify Merge - Items** → **Run now**.

  Why staging + MERGE rather than loading straight into master: the direct
  approach only works when master is empty at load time (`WRITE_TRUNCATE`
  wipes the destination). Once the daily Lambda has populated any rows into
  master, a direct historical load would delete them — and the 26-hour
  rolling window can't recover mutations that happened outside it. Going
  through staging + MERGE makes the historical load a superset of a daily
  run, so it composes cleanly with whatever the live pipeline has already
  written.

## 6. Operational Notes

- **Secrets.** Shopify tokens live only in SSM Parameter Store. Neither the Lambda nor the backfill script contains credentials. Rotate via the Shopify admin; no code change required. Infrastructure credentials that are not consumed by code in this repo (e.g. the AWS IAM user used by the BigQuery Data Transfer Service) are documented in [INFRA.md](INFRA.md).
- **Failure handling.** The Lambda runs each region in its own try/catch. Per-region failures are collected and thrown at the end so the Lambda invocation reports as failed, but one failing store does not prevent the other four from syncing.
- **Reprocessing.** Re-running the daily Lambda is safe — `MERGE` is idempotent. To backfill a gap, re-run the historical script for the affected month and let Data Transfer + `MERGE` resolve it.
- **Monitoring.** CloudWatch logs for the Lambda; BigQuery Data Transfer run history for loads; Scheduled Query run history for merges.

## 7. Known Limitations

- **No CloudWatch / EventBridge alarm is configured.** A failed Lambda invocation is visible in CloudWatch logs and in the Lambda console's invocation history, but no alarm or notification fires automatically. Operators need to check the dashboard (or the downstream BigQuery data) to notice a failed run. Adding a CloudWatch alarm on the `Errors` metric (e.g. `Errors > 0` over 1 evaluation period) with an SNS topic is the simplest fix and is recommended before this pipeline is treated as fully production-hardened.
- **No automated tests.** The codebase has no unit or integration tests. The transformation logic (`parseVariantInfo`, `mapOrdersPage`, `getNextUrl`, `fetchWithRetry`) is the highest-value target for a future test pass — bugs there would silently corrupt warehouse data.
- **Daily S3 objects accumulate under `daily/`.** The daily DTS configs match `daily/orders/*.csv` and `daily/items/*.csv` with `WRITE_TRUNCATE`, so every run re-loads every file ever written under those prefixes into staging. Correctness is unaffected (MERGE is idempotent and guarded by `updated_at`), but DTS load time and S3 storage cost grow linearly over time. A simple S3 lifecycle rule (e.g. delete or transition to Glacier after 7–30 days) or a post-load archive step would cap this. Not urgent while volume is small.

## 8. Querying Guidance (Claude Cowork)

- Query `peppermayo.orders_master` and `peppermayo.order_items_master` only. The `staging_*` tables are internal and overwritten daily.
- Join on `order_id`.
- Use standard SQL.
- Monetary values are in the order's native `currency`. Do not compare raw totals across regions without converting.
- Filter by `store_region` (`AU`, `US`, `UK`, `CA`, `EU`) for market-specific questions.
- Prefer filters on `DATE(created_at)` for time-bound queries so partition pruning kicks in.
