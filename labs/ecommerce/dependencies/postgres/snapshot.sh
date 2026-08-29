#!/usr/bin/env bash
# ecommerce PROJECT probe -- postgres snapshot phase.
#
# Captures the query plan of the deep-page product listing that scenario E03
# measures (ORDER BY id with a large OFFSET over the products table). Lives in
# the lab, not the shared postgres adapter, because the query and table are
# ecommerce schema. The shared adapter runs its generic captures first, then
# calls this via run_lab_dependency_hook.
set -euo pipefail
# shellcheck disable=SC1091
source "${PERFLAB_HARNESS_ROOT}/core/lib/common.sh"   # compose, pg_* config
artifact_dir="${1:?snapshot hook needs <artifact-dir>}"
mkdir -p "${artifact_dir}/dependencies"

compose exec -T "${pg_service}" psql -U "${pg_user}" -d "${pg_db}" -t -A -c \
  "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT id, name, description, price, stock, category_id FROM products WHERE is_active ORDER BY id OFFSET 12475 LIMIT 25" \
  > "${artifact_dir}/dependencies/postgres-product-plan.json"
