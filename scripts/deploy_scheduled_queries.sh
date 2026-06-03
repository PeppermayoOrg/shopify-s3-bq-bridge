#!/usr/bin/env bash
#
# Sync the MERGE SQL in this repo into the BigQuery Scheduled Queries that run
# them. BigQuery Scheduled Queries store their SQL inside the transferConfig
# resource, so there is no "point at a file" option — this script pushes the
# repo's SQL as the source of truth.
#
# Safe to run while the pipeline is live:
#   - It only patches the `query` param of each transferConfig.
#   - Schedule, destination, credentials, and run history are untouched.
#   - The next scheduled run picks up the new SQL automatically.
#
# Requirements:
#   - gcloud / bq CLI authenticated against the project that owns the configs
#   - jq
#
# Usage:
#   ./scripts/deploy_scheduled_queries.sh              # push all
#   ./scripts/deploy_scheduled_queries.sh orders       # orders only
#   ./scripts/deploy_scheduled_queries.sh items        # items only
#   ./scripts/deploy_scheduled_queries.sh fx           # fx merge only
#   ./scripts/deploy_scheduled_queries.sh customers    # customers refresh only
#   ./scripts/deploy_scheduled_queries.sh refundid     # refundid merge only
#
# The FX and Customers transferConfig IDs aren't hardcoded (they were
# added later). Either export them before running:
#
#   FX_CFG="projects/.../transferConfigs/..." \
#     CUSTOMERS_CFG="projects/.../transferConfigs/..." \
#     REFUNDID_CFG="projects/.../transferConfigs/..." \
#     ./scripts/deploy_scheduled_queries.sh all
#
# Or edit this script and set them inline next to ORDERS_CFG / ITEMS_CFG
# once you know the IDs.
#
# After running, verify in the BigQuery console:
#   BigQuery → Scheduled queries → open each one → confirm the SQL matches
#   the file and that "Next run" is still in the future.

set -euo pipefail

ORDERS_CFG="projects/229575872283/locations/australia-southeast1/transferConfigs/69e9381c-0000-24bd-966d-94eb2c1bbc54"
ITEMS_CFG="projects/229575872283/locations/australia-southeast1/transferConfigs/69e9389c-0000-24bd-966d-94eb2c1bbc54"
REFUNDS_CFG="projects/229575872283/locations/australia-southeast1/transferConfigs/69ea6feb-0000-20e7-8554-94eb2c1bbcd4"
REFUND_ITEMS_CFG="projects/229575872283/locations/australia-southeast1/transferConfigs/69e9bba0-0000-2454-93e7-3c286d400f8a"
FULFILLMENTS_CFG="projects/229575872283/locations/australia-southeast1/transferConfigs/69edafd8-0000-2766-88b4-3c286d33ef46"
FULFILLMENT_ITEMS_CFG="projects/229575872283/locations/australia-southeast1/transferConfigs/69ed4398-0000-2944-a0ca-94eb2c1bb6dc"
PRODUCTS_CFG="projects/229575872283/locations/australia-southeast1/transferConfigs/69ea8d00-0000-23ca-9040-94eb2c1b9828"
CUSTOMERS_CFG="projects/229575872283/locations/australia-southeast1/transferConfigs/69e9ec9f-0000-23a8-90ac-f403045d80ea"
FX_CFG="projects/229575872283/locations/australia-southeast1/transferConfigs/69ecec40-0000-220f-b077-94eb2c1bbb4e"
REFUNDID_CFG="${REFUNDID_CFG:-}"
# Populate these after creating the BQ Scheduled Queries in the console.
# See README.md → "BigQuery Scheduled Queries to configure" for the
# expected schedule and SQL file for each.
FX_CFG="${FX_CFG:-}"
CUSTOMERS_CFG="${CUSTOMERS_CFG:-}"
REFUNDS_CFG="${REFUNDS_CFG:-}"
REFUND_ITEMS_CFG="${REFUND_ITEMS_CFG:-}"
FULFILLMENTS_CFG="${FULFILLMENTS_CFG:-}"
FULFILLMENT_ITEMS_CFG="${FULFILLMENT_ITEMS_CFG:-}"
PRODUCTS_CFG="${PRODUCTS_CFG:-}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORDERS_SQL="$REPO_ROOT/sql/dml/merge_orders.sql"
ITEMS_SQL="$REPO_ROOT/sql/dml/merge_items.sql"
FX_SQL="$REPO_ROOT/sql/dml/merge_fx_rates.sql"
CUSTOMERS_SQL="$REPO_ROOT/sql/dml/refresh_customers_master.sql"
REFUNDS_SQL="$REPO_ROOT/sql/dml/merge_refunds.sql"
REFUND_ITEMS_SQL="$REPO_ROOT/sql/dml/merge_refund_line_items.sql"
FULFILLMENTS_SQL="$REPO_ROOT/sql/dml/merge_fulfillments.sql"
FULFILLMENT_ITEMS_SQL="$REPO_ROOT/sql/dml/merge_fulfillment_line_items.sql"
PRODUCTS_SQL="$REPO_ROOT/sql/dml/refresh_products_master.sql"
REFUNDID_SQL="$REPO_ROOT/sql/dml/merge_refundid_returns.sql"

command -v bq >/dev/null || { echo "bq CLI not found"; exit 1; }
command -v jq >/dev/null || { echo "jq not found"; exit 1; }

push() {
  local name="$1" cfg="$2" sql_file="$3"
  if [[ -z "$cfg" ]]; then
    echo "⚠ Skipping '$name' — transferConfig ID not set."
    echo "  Create the scheduled query in the BigQuery console first, then export the env var (see README.md)."
    return 0
  fi
  [[ -f "$sql_file" ]] || { echo "Missing $sql_file"; exit 1; }

  # Strip full-line SQL comments before upload. BigQuery's Scheduled Query
  # console collapses whitespace when it renders the saved query, which turns
  # `-- comment` lines into a comment that swallows the rest of the statement.
  # We keep the comments in the repo (for humans) and remove them at deploy
  # time so the stored SQL is newline-independent.
  local stripped
  stripped=$(mktemp)
  trap 'rm -f "$stripped"' RETURN
  grep -v -E '^\s*--' "$sql_file" | awk 'NF' > "$stripped"

  local params
  params=$(jq -Rs '{query: .}' < "$stripped")

  echo "→ Pushing $sql_file to '$name'"
  bq update \
    --transfer_config \
    --params="$params" \
    "$cfg"
  echo "✓ $name updated"
}

target="${1:-all}"
case "$target" in
  orders)            push "Daily Shopify Merge - Orders"           "$ORDERS_CFG"            "$ORDERS_SQL" ;;
  items)             push "Daily Shopify Merge - Items"            "$ITEMS_CFG"             "$ITEMS_SQL" ;;
  fx)                push "Daily FX Merge"                         "$FX_CFG"                "$FX_SQL" ;;
  customers)         push "Daily Customers Refresh"                "$CUSTOMERS_CFG"         "$CUSTOMERS_SQL" ;;
  refunds)           push "Daily Shopify Merge - Refunds"          "$REFUNDS_CFG"           "$REFUNDS_SQL" ;;
  refund_items)      push "Daily Shopify Merge - Refund Items"     "$REFUND_ITEMS_CFG"      "$REFUND_ITEMS_SQL" ;;
  fulfillments)      push "Daily Shopify Merge - Fulfillments"     "$FULFILLMENTS_CFG"      "$FULFILLMENTS_SQL" ;;
  fulfillment_items) push "Daily Shopify Merge - Fulfillment Items" "$FULFILLMENT_ITEMS_CFG" "$FULFILLMENT_ITEMS_SQL" ;;
  products)          push "Weekly Products Refresh"                "$PRODUCTS_CFG"          "$PRODUCTS_SQL" ;;
  refundid)          push "Daily Refundid Merge"                   "$REFUNDID_CFG"          "$REFUNDID_SQL" ;;
  all)
    push "Daily Shopify Merge - Orders"            "$ORDERS_CFG"            "$ORDERS_SQL"
    push "Daily Shopify Merge - Items"             "$ITEMS_CFG"             "$ITEMS_SQL"
    push "Daily Shopify Merge - Refunds"           "$REFUNDS_CFG"           "$REFUNDS_SQL"
    push "Daily Shopify Merge - Refund Items"      "$REFUND_ITEMS_CFG"      "$REFUND_ITEMS_SQL"
    push "Daily Shopify Merge - Fulfillments"      "$FULFILLMENTS_CFG"      "$FULFILLMENTS_SQL"
    push "Daily Shopify Merge - Fulfillment Items" "$FULFILLMENT_ITEMS_CFG" "$FULFILLMENT_ITEMS_SQL"
    push "Daily FX Merge"                          "$FX_CFG"                "$FX_SQL"
    push "Daily Customers Refresh"                 "$CUSTOMERS_CFG"         "$CUSTOMERS_SQL"
    push "Weekly Products Refresh"                 "$PRODUCTS_CFG"          "$PRODUCTS_SQL"
    push "Daily Refundid Merge"                    "$REFUNDID_CFG"          "$REFUNDID_SQL"
    ;;
  *) echo "Unknown target: $target (expected: orders | items | fx | customers | refunds | refund_items | fulfillments | fulfillment_items | products | refundid | all)"; exit 1 ;;
esac

echo
echo "Done. Verify in the BigQuery console → Scheduled queries."
