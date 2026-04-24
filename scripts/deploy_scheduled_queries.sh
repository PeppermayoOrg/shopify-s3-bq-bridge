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
#   ./scripts/deploy_scheduled_queries.sh           # push both
#   ./scripts/deploy_scheduled_queries.sh orders    # push orders only
#   ./scripts/deploy_scheduled_queries.sh items     # push items only
#
# After running, verify in the BigQuery console:
#   BigQuery → Scheduled queries → open each one → confirm the SQL matches
#   the file and that "Next run" is still in the future.

set -euo pipefail

ORDERS_CFG="projects/229575872283/locations/australia-southeast1/transferConfigs/69e9381c-0000-24bd-966d-94eb2c1bbc54"
ITEMS_CFG="projects/229575872283/locations/australia-southeast1/transferConfigs/69e9389c-0000-24bd-966d-94eb2c1bbc54"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORDERS_SQL="$REPO_ROOT/sql/dml/merge_orders.sql"
ITEMS_SQL="$REPO_ROOT/sql/dml/merge_items.sql"

command -v bq >/dev/null || { echo "bq CLI not found"; exit 1; }
command -v jq >/dev/null || { echo "jq not found"; exit 1; }

push() {
  local name="$1" cfg="$2" sql_file="$3"
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
  orders) push "Daily Shopify Merge - Orders" "$ORDERS_CFG" "$ORDERS_SQL" ;;
  items)  push "Daily Shopify Merge - Items"  "$ITEMS_CFG"  "$ITEMS_SQL" ;;
  all)
    push "Daily Shopify Merge - Orders" "$ORDERS_CFG" "$ORDERS_SQL"
    push "Daily Shopify Merge - Items"  "$ITEMS_CFG"  "$ITEMS_SQL"
    ;;
  *) echo "Unknown target: $target (expected: orders | items | all)"; exit 1 ;;
esac

echo
echo "Done. Verify in the BigQuery console → Scheduled queries."
