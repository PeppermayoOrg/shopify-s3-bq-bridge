# Peppermayo E-commerce Data Pipeline — Architecture

## 1. Overview

This pipeline synchronises order data from Peppermayo's five Shopify storefronts (AU, US, UK, CA, EU) and return data from Refundid into a single Google BigQuery warehouse. Nested Shopify JSON is flattened into a relational schema, PII is stripped at the extraction layer, and daily upserts keep the warehouse consistent with Shopify as orders move through their lifecycle.

The resulting warehouse is the source of truth for BI reporting and for LLM-assisted querying via Claude Cowork.

## 2. High-level Architecture

An ETL pipeline split across AWS (extract, stage as files) and GCP (load, transform, serve).

- **Extract** — Node.js Lambda calls the Shopify Admin REST API (`2026-01`) per storefront, the Frankfurter (ECB-backed) FX API for daily AUD-base rates, and the Refundid API for return processing. A separate weekly invocation of the same Lambda pulls the product catalog.
- **Transform** — Each order JSON is flattened into six flat tables (orders, line items, refunds, refund line items, fulfilments, fulfilment line items) in one pass. PII fields are dropped. Timestamps are kept as ISO 8601 strings; BigQuery parses them on load. FX rates are emitted as a seventh CSV. The weekly run produces two more (products, product_variants).
- **Stage (S3)** — CSVs are written to `s3://peppermayo-shopify-orders/daily/<entity>/` for the daily run, `weekly/<entity>/` for the weekly product pull, and `historical/<entity>/` for one-off backfills. Refundid data is written as JSONL to `daily/refundid/<region>/` and `historical/refundid/<region>/`.
- **Load (BigQuery)** — BigQuery Data Transfer Service pulls the latest CSVs into staging tables with `WRITE_TRUNCATE`.
- **Upsert (BigQuery)** — Scheduled Queries run `MERGE` statements from staging into the master tables. A final pair of scheduled queries rebuilds `customers_master` daily and `products_master` / `product_variants_master` weekly.
- **Semantic layer** — A family of `v_*` views sits on top of the master tables and exposes AUD/USD-normalised monetary columns, refund-adjusted unit counts, tag/discount arrays, Sydney-local date buckets, and friendly channel names. BI and LLM queries should target these views rather than the raw master tables.

## 3. Infrastructure

### 3.1 AWS

| Component | Purpose |
| --- | --- |
| Systems Manager Parameter Store | Stores the Shopify Admin API token for each store as a `SecureString`. Path: `/shopify/peppermayo-<region>/token`. Also stores Refundid tokens at `/refundid/peppermayo-<region>/token`. |
| Lambda (Node.js 24) | Runs two jobs, dispatched on `event.mode`. **Daily** (`mode` absent): reads the 26-hour rolling window of `updated_at`, writes six CSVs per region (orders, items, refunds, refund_items, fulfillments, fulfillment_items) to `/tmp`, uploads to S3. After all regions, makes a single call to Frankfurter for the day's AUD-base FX rates and writes a seventh CSV. Also runs the Refundid sync, placing JSONL data into `daily/refundid/`. **Weekly** (`mode: "products"`): pulls the full product catalog per region and writes two CSVs (products, product_variants) to `weekly/`. Regions process sequentially to prevent `/tmp` storage exhaustion. S3 uploads are wrapped in a retry-with-jitter layer on top of the SDK's internal retries. |
| EventBridge | Two rules. **Daily**: `cron(0 15 * * ? *)` at 15:00 UTC (01:00 AEST / 02:00 AEDT Sydney, next day) invokes the Lambda with an empty payload — runs the orders + FX sync. **Weekly**: `cron(0 14 ? * MON *)` at 14:00 UTC every Monday invokes the Lambda with `{"mode":"products"}` — runs the product catalog refresh. |
| S3 (`peppermayo-shopify-orders`) | Raw data lake. Retained for disaster recovery and reprocessing. Bucket versioning and default server-side encryption (AES256) are enabled. |
| IAM user for BigQuery DTS | Read-only access scoped to the S3 prefixes used by Data Transfer (`daily/orders/`, `daily/items/`, `daily/refunds/`, `daily/refund_items/`, `daily/fulfillments/`, `daily/fulfillment_items/`, `daily/fx/`, `daily/refundid/`, `weekly/products/`, `weekly/product_variants/`, plus the `historical/` prefixes for one-off backfills). |

The Lambda uses a 26-hour window (not 24) so that a delayed or retried run still picks up everything that landed during the gap. Orders touched twice in overlapping windows are deduped by the `MERGE`.

### 3.2 GCP

| Component | Purpose |
| --- | --- |
| BigQuery dataset `peppermayo` | Located in `australia-southeast1` (Sydney). All tables and views live here. |
| BigQuery Data Transfer Service | Ten Amazon S3 transfers. Eight daily transfers all scheduled 15:30 UTC (01:30 AEST / 02:30 AEDT Sydney): orders, items, refunds, refund_items, fulfillments, fulfillment_items, fx, refundid — each writing to the matching `staging_*` table. Two weekly transfers scheduled 14:30 UTC Mondays (00:30 AEST / 01:30 AEDT Tuesday): products, product_variants — writing to `staging_products` / `staging_product_variants`. All transfers use `WRITE_TRUNCATE`. Files under `historical/` are **not** watched by any DTS and must be loaded manually once the backfill completes (see §5). |
| BigQuery Scheduled Queries | Ten queries, all SQL synced from this repo via `scripts/deploy_scheduled_queries.sh` (`npm run deploy:sql`). Daily at 16:00 UTC: **Daily Shopify Merge - Orders** and **Daily Shopify Merge - Items**. 16:05 UTC: **Daily FX Merge**. 16:10 UTC: **Daily Shopify Merge - Refunds** then **Daily Shopify Merge - Refund Items**, then **Daily Shopify Merge - Fulfillments**, **Daily Shopify Merge - Fulfillment Items**, and **Daily Refundid Merge**. 16:15 UTC: **Daily Customers Refresh** (must run after all above — consumes v_orders/v_order_items which depend on refunds + fulfilments). Weekly Mondays 14:45 UTC: **Weekly Products Refresh** (`refresh_products_master.sql`). BigQuery stores each query's SQL text inside the scheduled-query resource itself, so `deploy:sql` is the only way in-repo SQL makes it into BigQuery. |
| BigQuery Views | The `v_*` family (`v_fx_rates_filled`, `v_orders`, `v_order_items`, `v_customers`, `v_daily_sales`, `v_monthly_sales`, `v_discount_code_performance`, `v_cohort_retention`, `v_refunds`, `v_fulfillments`, `v_products`, `v_product_variants`, `v_product_performance`) is deployed via `scripts/deploy_views.sh` (`npm run deploy:views`). Views are `CREATE OR REPLACE`, so the script is idempotent. |

## 4. Data Model

Several flat tables, joined on `order_id` or `refundid_id`. Nested arrays are avoided so the schema is easy for analysts (and LLMs) to reason about.

### 4.1 `peppermayo.orders_master`

Order-level financials and state.

- **Partitioning:** `DATE(created_at)` — keeps time-bound queries cheap (e.g. "sales this month").
- **Clustering:** `store_region`, `financial_status` — accelerates the two most common filters.
- **PII policy:** `customer_id` (INT64) is kept for cohort analysis. Name, email, phone, and street address are never written. `hashed_email` (unsalted SHA-256 of the lowercased email) is the only way to group orders by person without storing PII. Shipping country/region is available via `store_region` at a coarser grain and via `shipping_country_code` (ISO 3166-1 alpha-2) at the order grain.
- **Normalised statuses:** `fulfillment_status` is never NULL or empty — unfulfilled orders carry the explicit string `unfulfilled`. Downstream queries therefore don't have to special-case NULLs.

### 4.2 `peppermayo.order_items_master`

One row per line item.

- **Partitioning:** `DATE(created_at)` — `created_at` is denormalised from the parent order so this table can be partitioned the same way as `orders_master` and time-bound item queries stay cheap.
- **Clustering:** `store_region`, `order_id`, `sku` — accelerates region filters, order-level drill-downs, and product rollups.
- **Denormalised columns:** `store_region` and `created_at` are copied from the parent order. This keeps every per-region / per-period item query single-table and partition-pruned.
- **Transformation:** Shopify's free-text `variant_title` (formatted strictly as "Colour / Size") is parsed at extraction time into separate `colour` and `size` columns. The parser lives in [src/shared/utils.js](src/shared/utils.js) and is shared between the Lambda and the historical script.
- **Known limitation:** `quantity` reflects the ordered quantity at time of purchase. For refund-adjusted units query `v_order_items.quantity_net` (which subtracts `quantity_refunded` from `refund_line_items_master`). For shipped-units query `v_order_items.quantity_fulfilled`.

### 4.3 `peppermayo.fx_rates_master`

One row per `(rate_date, currency)` with the multiplier to convert a native-currency amount to AUD (`rate_to_aud`).

- **Source:** [Frankfurter](https://www.frankfurter.dev/), which republishes ECB reference rates. Free, no API key, same trust anchor most accounting systems use so numbers reconcile with Xero/NetSuite.
- **Cadence:** The daily Lambda appends one snapshot per run (five rows: AUD, USD, GBP, CAD, EUR) to `daily/fx/fx_YYYY-MM-DD.csv`. The same third DTS config + `merge_fx_rates.sql` load path handles both daily and the one-off historical backfill.
- **Weekends / holidays:** Frankfurter only publishes business days. The `v_fx_rates_filled` view forward-fills from the most recent prior rate so every calendar date has a usable row. **Always join `v_fx_rates_filled`, never `fx_rates_master`, for currency conversion.**
- **AUD self-row:** Every date carries an AUD row with `rate_to_aud = 1.0` so downstream joins work uniformly regardless of the order's native currency.

### 4.4 `peppermayo.customers_master`

One row per `customer_id`. Built by a scheduled `CREATE OR REPLACE TABLE` (`sql/dml/refresh_customers_master.sql`) that runs at 16:15 UTC, after the orders/items merges. Carries lifetime order count, AUD/USD revenue, acquisition region, first discount code, recency, and a repeat-customer flag. Guest checkouts (NULL `customer_id`) are excluded.

`v_customers` wraps this table and adds a `recency_bucket` derived column (active / lapsing / dormant / churned) and the Sydney-local acquisition cohort month. Prefer the view over the raw table.

### 4.5 Semantic layer (views)

All BI and LLM querying should target these views rather than the master tables directly. Every view is defined in [sql/ddl/views/](sql/ddl/views/) and deployed via `npm run deploy:views`.

| View | Grain | Purpose |
| --- | --- | --- |
| `v_fx_rates_filled` | `rate_date × currency` | Gap-filled FX rates. Infrastructure; queried indirectly via `v_orders` / `v_order_items`. |
| `v_orders` | order | Wraps `orders_master` with AUD/USD monetary columns, tag/discount arrays, friendly channel name, Sydney-local date buckets, convenience booleans, **plus** refund aggregates (`refund_count`, `refund_amount_aud/usd`, `refunded_units`, `net_revenue_aud/usd`) and fulfilment aggregates (`successful_fulfillment_count`, `first_fulfilled_at`, `latest_shipment_status`, `hours_to_first_fulfillment`). |
| `v_order_items` | line item | `order_items_master` joined to `v_orders` with AUD/USD normalised price and line revenue. Includes `quantity_refunded`, `quantity_fulfilled`, `quantity_net`, `line_net_revenue_aud/usd`. |
| `v_refunds` | refund | `refunds_master` with AUD/USD refund amounts and Sydney-local `processed_date` / `processed_month`. |
| `v_fulfillments` | fulfilment | `fulfillments_master` with `is_successful`, `is_delivered` booleans, `hours_to_ship`, and the parent order's `customer_id` / `total_price_aud`. |
| `v_products` | product | `products_master` with `is_active`, `is_published`, Sydney-local `created_date`. |
| `v_product_variants` | variant | `product_variants_master` joined to `products_master` for product_type/vendor/tags context; `is_out_of_stock`. |
| `v_product_performance` | `month × store × product` | Refund-adjusted product performance. `units_net`, `net_revenue_aud`, refund subtotals, distinct customers/orders. Filters out cancelled orders and gift cards. |
| `v_customers` | customer | `customers_master` plus `recency_bucket` and acquisition cohort. |
| `v_daily_sales` | `date × region × channel` | Pre-aggregated sales: orders, distinct customers, gross/net revenue, discounts, AOV. AUD and USD. |
| `v_monthly_sales` | `month × region` | Monthly rollup (Sydney-local months). |
| `v_discount_code_performance` | `code × month × region` | Per-code orders, revenue, average discount depth, average customer LTV. |
| `v_cohort_retention` | `cohort_month × cohort_region × months_since_acquisition` | Retention count, retention %, cohort revenue over time. |
| `v_pipeline_health` | storefront | `MAX(updated_at)` per region across orders / refunds / fulfillments, last FX date, last product refresh, and `fresh` / `stale` / `broken` freshness labels. Query before trusting any "why is today's revenue low?" answer. |

Every view's columns carry `OPTIONS(description=...)` entries in the master-table DDL from which they derive, so BQ Studio / Claude Cowork can consume them via `INFORMATION_SCHEMA.COLUMN_FIELD_PATHS` without any extra configuration.

See [sql/ddl/create_master_tables.sql](sql/ddl/create_master_tables.sql), [sql/ddl/create_staging_tables.sql](sql/ddl/create_staging_tables.sql), [sql/ddl/create_fx_tables.sql](sql/ddl/create_fx_tables.sql), and [sql/ddl/views/](sql/ddl/views/) for the full schema.

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
- **Alerting.** A CloudWatch alarm on the Lambda's `Errors` metric (`Errors > 0` over 5 minutes) publishes to an SNS topic; a second alarm on `Invocations < 1` over a rolling 28-hour window catches the case where EventBridge itself is misconfigured. Setup is documented in [INFRA.md](INFRA.md).
- **Freshness self-check.** `peppermayo.v_pipeline_health` exposes `MAX(updated_at)` per storefront, last FX date, last product refresh, and a `fresh` / `stale` / `broken` label per region. Query it from BI / the LLM before trusting any "yesterday's revenue was $0" answer.

## 7. Known Limitations

- **CloudWatch alarms are infra-level and live outside this repo.** Both alarms described in §6 (Errors > 0 and Invocations < 1) are configured; see [INFRA.md](INFRA.md) for details.
- **No automated tests.** The codebase has no unit or integration tests. The transformation logic (`mapOrdersPage`, `getNextUrl`, `fetchWithRetry`) is the highest-value target for a future test pass.
- **Strict Variant Parsing (`parseVariantInfo`):** The extraction logic assumes Shopify's `variant_title` strictly follows the `"Colour / Size"` format (e.g., "Red / Large"). If a merchandiser changes the naming convention (e.g., using a hyphen like "Large - Red" or dropping the spaces around the slash), the parser will silently fail or assign values to the wrong columns. This can cause downstream LLM hallucinations if users ask questions about specific colors or sizes.
- **Daily S3 objects accumulate under `daily/`.** The daily DTS configs match `daily/orders/*.csv` and `daily/items/*.csv` with `WRITE_TRUNCATE`, so every run re-loads every file ever written under those prefixes into staging. Correctness is unaffected (MERGE is idempotent and guarded by `updated_at`), but DTS load time and S3 storage cost grow linearly over time. A simple S3 lifecycle rule (e.g. delete or transition to Glacier after 7–30 days) or a post-load archive step would cap this. Not urgent while volume is small.

## 8. Querying Guidance (Claude Cowork)

**Always prefer the `v_*` views over the raw master tables.** The views carry friendly column names, AUD/USD-normalised monetary columns, Sydney-local date buckets, tag/discount arrays, and boolean status flags that encode the business definitions the team agrees on.

- **Top-level surfaces.** Use `v_orders` and `v_order_items` for transactional questions, `v_customers` for customer-level questions, and the pre-aggregated `v_daily_sales` / `v_monthly_sales` / `v_discount_code_performance` / `v_cohort_retention` for reporting. The `staging_*` tables are internal and overwritten daily.
- **Join key.** Orders ↔ items on `order_id`. Orders ↔ customers on `customer_id` (NULL for guest checkouts).
- **Currency.**
  - Cross-region totals: use `*_aud` (e.g. `total_price_aud`, `line_revenue_aud`, `gross_revenue_aud`). AUD is the reporting currency.
  - US-only dashboards: use `*_usd`.
  - Single-region, native-currency reconciliation (e.g. comparing to Shopify's own UK dashboard): use the un-suffixed native columns on `v_orders` / `v_order_items`, but filter `store_region` to one region first.
  - **Never** `SUM` the native monetary columns across regions — that silently mixes currencies.
- **Revenue semantics (canonical across the warehouse).**
  - `gross_revenue_aud` / `gross_revenue_usd` = `total_price_aud` / `total_price_usd` — pre-refund, post-discount, includes tax+shipping.
  - `net_revenue_aud` / `net_revenue_usd` = `current_total_price_aud` / `current_total_price_usd` — **Shopify's post-refund figure**. This is the canonical net revenue and reconciles with Shopify's own dashboards.
  - `net_revenue_from_refunds_aud` on `v_orders` is a diagnostic variant (`total_price − SUM(refund_amount)`). Use only when auditing discrepancies vs Shopify's `current_total_price`.
- **Statuses.** `v_orders` exposes boolean flags (`is_cancelled`, `is_refunded_full`, `is_refunded_partial`, `is_unfulfilled`). Use those rather than raw status strings. `v_daily_sales`, `v_monthly_sales`, `v_discount_code_performance`, `v_cohort_retention`, and `v_product_performance` **already exclude cancelled orders** — do not add `WHERE NOT is_cancelled` on top. `v_product_performance` also already excludes gift cards.
- **Quantities.** `order_items.quantity` / `v_order_items.quantity` is the quantity **ordered** at time of purchase — it is **not** net of refunds. For refund-adjusted units use `v_order_items.quantity_net` (ordered − refunded, floored at 0); for shipped units use `v_order_items.quantity_fulfilled`. `customers_master.lifetime_units` and `lifetime_net_revenue_aud` are refund-adjusted.
- **Refunds and fulfilment.** Use `v_refunds` for refund-level questions (monthly refund rates, refund reasons via `note`). Use `v_fulfillments` for shipping-speed questions (`hours_to_ship`) and tracking. `v_orders` already exposes roll-ups (`refund_amount_aud`, `net_revenue_aud`, `refund_count`, `first_fulfilled_at`, `latest_shipment_status`) so most questions don't need the detail views.
- **Product performance.** Use `v_product_performance` for per-product revenue/unit analytics — it's refund-adjusted and pre-excludes cancelled orders and gift cards. For catalog-only questions (which products exist, which are active) use `v_products` / `v_product_variants`.
- **Customer lifecycle — lifetime vs per-order.**
  - `customers_master.is_repeat_customer` and `customers_master.is_churned` are **lifetime/snapshot** flags (evaluated at refresh time). Use them for "how many of our customers are currently churned?".
  - For "repeat customer rate in month M" (the share of orders in a given month placed by returning customers), use `v_orders.is_returning_customer_order`.
  - For "customers who came back after churning" or "which discount codes win back churned customers", use `v_orders.is_reactivation_order` and `days_since_previous_order`.
- **Regional LTV.** `first_order_region` is acquisition only; the customer's revenue may come from multiple regions. Use `regions_purchased_in` to ask "has this customer ever ordered in UK?" and `lifetime_revenue_by_region` (UNNEST) to break lifetime revenue down by storefront.
- **Data freshness.** Before answering any "why is X low/zero?" question, check `v_pipeline_health.overall_status`. `'broken'` means at least one region's sync is down (or FX coverage has a hole) and any revenue answer will mislead.
- **Regions.** Filter by `store_region` (`AU`, `US`, `UK`, `CA`, `EU`) for market-specific questions. For shipping-destination questions use `shipping_country_code` (ISO alpha-2) on `v_orders`.
- **Time.** Prefer Sydney-local buckets: `created_date_sydney` / `created_month_sydney` on `v_orders`, `sales_date` on `v_daily_sales`, `sales_month` on `v_monthly_sales`. Partition pruning still applies — BigQuery recognises the underlying `DATE(created_at)` partition when you filter on the Sydney-local columns.
- **Customers.** `customer_id` is INT64 and NULL for guest checkouts (excluded from `customers_master` / `v_customers`). `hashed_email` (SHA-256) is the only way to group guest orders by person. `v_daily_sales` / `v_monthly_sales` expose `distinct_customers` (identified only) and `distinct_customers_incl_guests` (guests counted by hashed_email).
- **Tags / discount codes.** Use the array columns on `v_orders` (`tags_array`, `discount_codes_array`) with `UNNEST`. `discount_codes_array` values are already trimmed of whitespace. The raw comma-separated strings on `orders_master` exist for compatibility only.

### 8.1 System prompt for Claude Cowork

Paste the following into Claude Cowork's system-prompt / custom-instructions field. It encodes the rules above as imperative guidance so the LLM pre-commits to the right column names, filters, and caveats before generating SQL.

```text
You are a BigQuery analytics assistant for Peppermayo, a multi-region Shopify
retailer. All data lives in the `peppermayo` dataset in australia-southeast1.
Follow these rules for every query.

## Always do this first
1. Before answering any question whose answer depends on "today" or
   "yesterday" / the current week or month, run:
     SELECT store_region, orders_freshness, products_freshness,
            days_since_last_fx, fx_coverage_ok, overall_status
     FROM peppermayo.v_pipeline_health
   If overall_status != 'fresh', preface your answer with a caveat naming
   the stale region(s) / reason and timestamp.
2. Prefer `v_*` views over `*_master` tables. Never query `staging_*`.

## Revenue definitions (canonical)
3. "Gross revenue" / "sales" / "revenue" (unqualified) = total_price_aud /
   gross_revenue_aud (SUM). Pre-refund, post-discount, incl. tax+shipping.
4. "Net revenue" = current_total_price_aud / net_revenue_aud (SUM).
   This is Shopify's post-refund figure and reconciles with Shopify
   dashboards. DO NOT use net_revenue_from_refunds_aud for reporting —
   that column is diagnostic only.
5. Never SUM native-currency columns (total_price, subtotal_price, price)
   across regions. Always use *_aud / *_usd, or filter to a single
   store_region first.

## Cancelled orders and gift cards
6. These views ALREADY exclude cancelled orders: v_daily_sales,
   v_monthly_sales, v_discount_code_performance, v_cohort_retention,
   v_product_performance. Do NOT add WHERE NOT is_cancelled on top.
7. v_orders and v_order_items DO NOT exclude cancellations. Add
   WHERE NOT is_cancelled whenever the answer should be revenue-bearing.
8. v_product_performance ALSO pre-excludes gift cards. v_order_items does
   not — add AND NOT gift_card if needed.

## Quantities
9. v_order_items.quantity = units ordered (pre-refund). For "units sold" or
   sell-through, use quantity_net. For "units shipped", use quantity_fulfilled.
10. customers_master.lifetime_units is already refund-adjusted and excludes
    gift cards. lifetime_units_ordered / lifetime_units_refunded are split
    so you can compute per-customer return rates directly — or just use
    customers_master.lifetime_return_rate.

## Customer lifecycle — lifetime vs per-order
11. customers_master.is_repeat_customer and is_churned are LIFETIME /
    SNAPSHOT flags (evaluated at refresh time).
12. For "repeat customer rate in month M" (share of orders placed by
    returning customers in that month), use
    v_orders.is_returning_customer_order. Do NOT use is_repeat_customer
    for monthly trends — it will produce a monotonic, misleading curve.
13. For "customers who came back after churning" or "which discount codes
    win back churned customers", use v_orders.is_reactivation_order
    (true when days_since_previous_order > 180) and
    v_orders.discount_codes_array. Do NOT use is_churned — it's a
    snapshot and misses historical reactivation.

## Regions and regional LTV
14. store_region is the storefront (AU/US/UK/CA/EU) the order was placed in,
    NOT the shipping destination. For "sales to UK" use store_region='UK'.
    For "orders shipping to Germany" use shipping_country_code='DE' on v_orders.
15. customers_master.first_order_region is acquisition only. A customer's
    revenue can come from any region.
16. For "top UK customers by LTV", clarify the intent. Options:
    (a) Customers acquired in UK: WHERE first_order_region = 'UK',
        sort by lifetime_revenue_usd / lifetime_net_revenue_usd.
    (b) Customers who have ever ordered in UK: WHERE 'UK' IN UNNEST(regions_purchased_in),
        sort by whole-customer LTV.
    (c) UK-only LTV: UNNEST(lifetime_revenue_by_region) r WHERE r.region='UK',
        sort by r.net_revenue_usd.
    State which interpretation you are using.

## Discount codes
17. v_orders.discount_codes_array values are already trimmed. Filter with
    `code = 'WELCOME10'` on unnested values; no TRIM() needed.
18. v_discount_code_performance UNNESTS codes. Do NOT under any circumstances SUM(orders) or SUM(gross_revenue_aud) from this view, as it will double-count revenue for multi-code orders. Only use this view for sorting/ranking specific codes.

## FX and currency
19. All AUD/USD columns derive from v_fx_rates_filled. If you see unexpected
    NULL revenue in AUD, check v_pipeline_health.fx_coverage_ok. If FALSE,
    flag the exclusion in your answer — do not silently aggregate NULLs.

## Dates and Partitioning
20. When filtering on dates, always filter on the underlying partition column
    DATE(created_at) in addition to Sydney-local columns to ensure BigQuery
    partition pruning applies (e.g., WHERE DATE(created_at) >= '2026-03-31'
    AND created_date_sydney >= '2026-04-01').

## SQL Best Practices & Caveats
21. Always use SAFE_DIVIDE(numerator, denominator) for ratios, percentages, 
    and averages to prevent division-by-zero errors.
22. When a user's question maps ambiguously onto the schema (e.g. "UK
    customers", "net revenue", "repeat rate"), state the interpretation
    you chose before giving numbers.
23. If v_pipeline_health.overall_status is 'degraded' or 'broken', name
    the affected region(s) or issue in the first sentence of your answer.
24. Never invent columns. If the dataset does not expose what is needed,
    say so — do not hallucinate a plausible-looking query.
```
