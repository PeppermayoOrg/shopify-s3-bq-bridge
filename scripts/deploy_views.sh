#!/usr/bin/env bash
#
# Deploy every .sql file under sql/ddl/views/ to BigQuery. Each file is
# expected to contain a CREATE OR REPLACE VIEW statement and is therefore
# idempotent — safe to re-run any time.
#
# Views are deployed via `bq query` (not via the scheduled-query transferConfig
# mechanism that merge_*.sql uses) because a view is a schema object, not
# a recurring job.
#
# Usage:
#   ./scripts/deploy_views.sh            # deploy all views
#   ./scripts/deploy_views.sh v_orders   # deploy one view by filename stem
#
# Requirements:
#   bq CLI authenticated against the project that owns the `peppermayo`
#   dataset.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIEWS_DIR="$REPO_ROOT/sql/ddl/views"

command -v bq >/dev/null || { echo "bq CLI not found"; exit 1; }

deploy() {
  local file="$1"
  local name
  name="$(basename "$file" .sql)"
  echo "→ Deploying $name"
  bq query --use_legacy_sql=false --format=none < "$file"
  echo "✓ $name deployed"
}

# Dependency order matters: v_fx_rates_filled must exist before v_orders,
# and v_orders before v_order_items / v_customers / v_*_sales. We deploy
# all files but prioritise the dependency leaders.
DEPENDENCY_ORDER=(
  "v_fx_rates_filled"
  "v_orders"
  "v_order_items"
  "v_customers"
  "v_daily_sales"
  "v_monthly_sales"
  "v_discount_code_performance"
  "v_cohort_retention"
  "v_refunds"
  "v_fulfillments"
  "v_products"
  "v_product_variants"
  "v_product_performance"
  "v_pipeline_health"
)

target="${1:-all}"

if [[ "$target" != "all" ]]; then
  file="$VIEWS_DIR/$target.sql"
  [[ -f "$file" ]] || { echo "View not found: $file"; exit 1; }
  deploy "$file"
  exit 0
fi

# Deploy in dependency order, then anything not explicitly ordered.
deployed=()
for name in "${DEPENDENCY_ORDER[@]}"; do
  file="$VIEWS_DIR/$name.sql"
  if [[ -f "$file" ]]; then
    deploy "$file"
    deployed+=("$name")
  fi
done

for file in "$VIEWS_DIR"/*.sql; do
  name="$(basename "$file" .sql)"
  # shellcheck disable=SC2076
  if [[ ! " ${deployed[*]} " =~ " ${name} " ]]; then
    deploy "$file"
  fi
done

echo
echo "Done. Verify in the BigQuery console → peppermayo dataset → Views."
