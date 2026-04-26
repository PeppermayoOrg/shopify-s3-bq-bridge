# Data Integrity Verification

Step-by-step instructions for verifying that the BigQuery warehouse
matches Shopify. Run this whenever you need confidence the pipeline is
producing correct numbers — after the initial backfill, after any
gap-fill, after schema changes, or as a periodic audit (e.g. quarterly).

All checks are read-only against both Shopify and BigQuery. Nothing in
this guide mutates data.

---

## What "correct" means

The warehouse is a **snapshot at the last merge**, while Shopify is
**live**. They can never agree on an instantaneous comparison because
the daily Lambda runs at 15:00 UTC and orders/refunds/fulfillments are
mutating continuously. The verifier accounts for this by capping every
comparison at the **pipeline cutoff** = the most recent 14:55 UTC
(Lambda start − 5 min). At that moment both sides agree on:

- The set of orders that exist (membership)
- Each order's `created_at` (immutable)
- Refund / fulfillment line item membership (additive only — see notes)

What the verifier deliberately does **not** check via aggregate counts:

- `financial_status` / `fulfillment_status` — mutable; Shopify's
  `count.json` filters on the *current* `updated_at`, BQ stores the
  snapshot at last merge. The two will systematically disagree by the
  size of the in-flight mutation set. Use `verify:spotcheck` instead.

---

## Prerequisites

```sh
# 1. AWS + GCP CLIs authenticated
gcloud auth list           # should show your @peppermayo.com account
gcloud config get project  # should be the warehouse project
bq ls peppermayo           # should list orders_master, products_master, etc.

# 2. Shopify Admin API tokens in .env (same as backfill)
grep SHOPIFY_TOKEN_ .env   # AU/US/UK/CA/EU all set
```

`bq` reads via the local CLI, so whoever runs the verifier needs read
access to the `peppermayo` dataset.

---

## The 4 verification modes

| Mode | What it checks | Cost | Time |
| --- | --- | --- | --- |
| `counts` | Per-region + per-month order counts; product catalog totals | ~6 API calls × months + 5 product calls | seconds–minutes |
| `revenue` | Sum(subtotal/discounts/tax/shipping/total) per region for one month, native currency | Paginates every order in the month | 5–15 min for a busy month |
| `spotcheck` | Picks N random orders/region from BQ, deep-compares every mapped field including line items, refunds, fulfillments | 5 × N order fetches | seconds–minutes |
| `diff` | Lists exact order IDs that are in Shopify but missing from BQ (or vice versa) for one (region, month) | Paginates the window | minutes |

You should run **all four** for a full audit. `counts` is the cheapest
gate; the others surface different classes of bug.

---

## Step 1 — Counts (always start here)

Validates membership and per-month boundaries across the full history.

```sh
# Full history, every region, every month
npm run verify:counts

# Or bound to a date range (inclusive, YYYY-MM)
npm run verify:counts -- 2024-01 2024-12
```

**Expected output**: `5 ok 0 warn 0 fail` plus one OK line per region
saying "all N months match", and one OK per region for product counts
(or a `warn` for products of a couple-percent drift, which is normal —
weekly DTS lag).

**If you see a fail**, e.g.:

```text
✗ AU 2024-10: BQ=1234 Shopify=1292 (delta=-58)
```

Go to Step 2 to identify the exact missing IDs, then Step 5 to recover.

> **Fence-post bugs**: If a fail shows `delta=-1` (or `+1`) for a
> single month, it's almost always an order created at exactly
> `YYYY-MM-01T00:00:00Z`. The verifier already corrects for Shopify's
> inclusive `created_at_max`; if you see one, double-check the order's
> `created_at` UTC timestamp via `verify:diff` before assuming
> something is wrong.

---

## Step 2 — Diff (only when counts fails)

Enumerates the symmetric difference between BQ and Shopify order IDs
for one (region, month). For each missing ID, looks the order up in
Shopify and prints `name / created_at / updated_at / financial_status /
cancelled_at / test`.

```sh
npm run verify:diff -- au 2024-10
```

**Common findings** for missing-from-BQ orders:

| Cause | Tell-tale |
| --- | --- |
| Test order | `test=true` (Lambda filters these by design) |
| Boundary timestamp | `created_at = YYYY-MM-01T00:00:00Z` exactly (already corrected) |
| Recent gap-fill not yet merged | `updated_at > pipeline cutoff` |
| Genuine pipeline gap | none of the above — this is the case to fix in Step 5 |

Save the list of months that show genuine gaps. You'll use them in
Step 5.

---

## Step 3 — Revenue

Sums every monetary total for one month, native currency, per region.
This catches mapping bugs (wrong column, wrong field, lost decimals)
that count checks can't see.

```sh
npm run verify:revenue -- 2026-04   # one specific month
npm run verify:revenue              # defaults to current month
```

For each region you'll see ~one log line per Shopify page (250
orders), so a 5,000-order month produces ~20 lines. Then:

```text
✓ AU orders: 4827
✓ AU subtotal_price: 412384.50
✓ AU total_discounts: 18230.10
✓ AU total_tax: 41238.45
✓ AU total_shipping_price: 23415.00
✓ AU total_price: 459807.85
✓ AU current_total_price: 442012.20
```

Tolerances: 1¢ absolute or 0.001% relative — surface-level rounding
drift won't fail the check.

**Rotate** through several months when auditing — at minimum:

- Current month (catches today's bugs)
- Previous month (catches month-rollover bugs)
- A high-volume sale month (e.g. November / Boxing Day) — catches
  pagination / rate-limit edge cases under load

---

## Step 4 — Spotcheck (deepest, narrowest)

For each region, picks N random `order_id`s from `orders_master`,
fetches each from Shopify by ID, runs them through the same
`mapOrdersPage()` the Lambda uses, and deep-compares every mapped
column on the order, every line item, every refund, every refund line
item, every fulfillment, and every fulfillment line item.

```sh
npm run verify:spotcheck            # default 20 orders/region (= 100 total)
npm run verify:spotcheck -- 50      # 50 orders/region  = 250 total
npm run verify:spotcheck -- 200     # thorough audit
```

This is the **only** check that validates mutable status fields
(`financial_status`, `fulfillment_status`, refund amounts, etc.) and
nested structures. Run with `-- 50` minimum for any audit you intend
to sign off on.

If a field mismatches, the script prints `BQ=<value>  Shopify=<value>`
side by side. The most common categories:

- **Numeric**: re-check `mapOrdersPage` in [src/shared/utils.js](src/shared/utils.js)
- **Enum / string**: BQ snapshot is older than Shopify mutation —
  benign if the order's `updated_at` is recent; problematic otherwise
- **Missing line item / refund**: pipeline gap, go to Step 5

---

## Step 5 — Recover gaps

Only run this if Steps 1–4 surfaced genuine gaps (not boundary effects,
not test orders, not in-flight mutations).

### 5a. Run a targeted backfill

Edit `BACKFILL_MONTHS` near the bottom of
[scripts/historical_sync.js](scripts/historical_sync.js):

```js
const BACKFILL_MONTHS = [
  { region: "au", month: "2024-10" },
  // add more (region, month) pairs here
];
```

Then:

```sh
npm run backfill:gaps
```

This re-fetches Shopify for the listed (region, month) pairs and
uploads to `s3://peppermayo-shopify-orders/historical/{orders,items,
refunds,refund_items,fulfillments,fulfillment_items}/au_*_historical_2024-10.csv`.
The merge guard `S.updated_at > T.updated_at` makes re-loading safe;
unchanged rows are no-ops.

### 5b. Re-run the historical DTS + merges

In a window that does **not** cross the daily 15:30 UTC DTS
(safest: shortly after 16:00 UTC), in the BigQuery console:

1. **Data Transfers** → `Historical Orders → Staging` → **Schedule backfill** → run
2. **Scheduled Queries** → `Daily Shopify Merge - Orders` → **Schedule backfill** → run, wait
3. **Data Transfers** → `Historical Items → Staging` → run
4. **Scheduled Queries** → `Daily Shopify Merge - Items` → run, wait
5. `Historical Refunds → Staging` → run
6. `Daily Shopify Merge - Refunds` → run, wait
7. `Historical Refund Items → Staging` → run
8. `Daily Shopify Merge - Refund Items` → run, wait
9. `Historical Fulfillments → Staging` → run
10. `Daily Shopify Merge - Fulfillments` → run, wait
11. `Historical Fulfillment Items → Staging` → run
12. `Daily Shopify Merge - Fulfillment Items` → run, wait
13. `Daily Customers Refresh` → run (rebuilds `customers_master`)

FX and products are usually not affected by an order-side gap-fill —
skip them unless `verify:counts` flagged the products line.

### 5c. Re-verify

```sh
npm run verify:counts -- 2024-10 2024-10
npm run verify:diff   -- au 2024-10
```

Both should now be clean. If not, repeat 5a/5b — the most common cause
of a re-fail is running 5b while the daily DTS was firing and
truncating staging mid-flight.

---

## Quick-audit recipe (≈ 20 minutes)

For routine confidence checks without a full sweep:

```sh
npm run verify:counts                              # all history, all regions
npm run verify:revenue   -- $(date -u +%Y-%m)      # current month
npm run verify:revenue   -- $(date -u -v-1m +%Y-%m 2>/dev/null || \
                             date -u -d '1 month ago' +%Y-%m)  # last month
npm run verify:spotcheck -- 50                     # 250 orders deep-compared
```

Pass criteria: `0 fail` across all four.

---

## Full-audit recipe (≈ 1–2 hours, run quarterly)

```sh
npm run verify:counts                                            # full history

# Revenue: pick one month per quarter going back as far as you want
for ym in 2026-01 2025-10 2025-07 2025-04 2025-01 2024-10 \
          2024-07 2024-04 2024-01 2023-10 2023-07 2023-04; do
  npm run verify:revenue -- $ym
done

npm run verify:spotcheck -- 200                                  # 1000 orders
```

Pass criteria: `0 fail` everywhere. `warn`s on product catalog drift
are acceptable (weekly cadence).

---

## Determinism for CI

Set `MERGE_CUTOFF` to pin the comparison cutoff to a fixed instant. All
checks will use that timestamp instead of "most recent 14:55 UTC":

```sh
MERGE_CUTOFF='2026-04-25T14:55:00Z' npm run verify:counts
```

Useful for reproducing a flaky failure: pin the cutoff to the time the
original run used (visible in the verifier's first line of output).

---

## Known limitations (warn, not fail)

The verifier deliberately demotes two classes of mismatch to `warn`
because they reflect Shopify-side quirks rather than pipeline bugs.
You'll still see them in the output so they remain auditable, but they
don't block a clean run.

### `order_number` NULL in BQ

Shopify's `/orders.json` **list** endpoint (used by the daily Lambda
and historical backfill) does not always populate `order_number` —
particularly for orders touched by Order Editing, the Returns API, or
draft-order completion. The single-order endpoint
`/orders/{id}.json` (used by `verify:spotcheck`) always recomputes it.

Result: BQ has `NULL`, Shopify has e.g. `1580218`. **Use `name`** for
the canonical display number (e.g. `#PMAU500570450`); `order_number`
should be treated as a best-effort field. The verifier prints:

```text
⚠ US order 12185963168116 order_number: BQ=NULL Shopify='1580218' (list-endpoint quirk; use `name` for display)
```

### `shipment_status` forward-only drift

Shopify mutates `fulfillment.shipment_status` as carrier tracking
events arrive (`label_printed → confirmed → in_transit →
out_for_delivery → delivered`) but **does not always bump the parent
`order.updated_at`** when only fulfilment-level fields change. The
daily Lambda windows on `orders.updated_at`, so post-fulfilment
shipment progressions can lag in BQ until the order is touched for an
unrelated reason.

The verifier accepts BQ at an *earlier* stage than Shopify as benign
(forward-only carrier drift). Backward movement — Shopify *behind* BQ,
or transitions to/from unknown stages — still hard-fails.

```text
⚠ US order 12185963168116 fulfillments 7012409246068 shipment_status: BQ='in_transit' Shopify='delivered' (forward-only carrier drift, OK)
```

If this drift becomes operationally important (e.g. the BI team needs
near-real-time delivery state), the structural fix is a separate
fulfilment-delta sync keyed on `fulfillment.updated_at` rather than
`order.updated_at`.

### Status-only fields (financial / fulfillment status)

Aggregate `count.json` checks for these are intentionally skipped
(see the comment in [scripts/verify_data.js](scripts/verify_data.js#L347)).
`spotcheck` still hard-checks them per order, on the assumption that a
random sample shouldn't all be in flight at once. Persistent
`spotcheck` mismatches on `financial_status` for orders whose
Shopify `updated_at` is older than the pipeline cutoff *are* genuine
pipeline bugs — investigate.

---

## Reference: what each check reads

| Mode | BigQuery tables | Shopify endpoints |
| --- | --- | --- |
| `counts` | `orders_master`, `products_master` | `/orders/count.json`, `/products/count.json` |
| `revenue` | `orders_master` | `/orders.json` (paginated) |
| `spotcheck` | `orders_master`, `order_items_master`, `refunds_master`, `refund_line_items_master`, `fulfillments_master`, `fulfillment_line_items_master` | `/orders/{id}.json` |
| `diff` | `orders_master` | `/orders.json` (paginated) + `/orders/{id}.json` for samples |

Source: [scripts/verify_data.js](scripts/verify_data.js).
