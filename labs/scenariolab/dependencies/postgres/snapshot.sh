#!/usr/bin/env bash
# scenariolab PROJECT probe -- postgres snapshot phase.
#
# Captures the query plan of the deep-page order query that scenario S08
# measures. This lives in the LAB, not in the shared postgres adapter, because
# the query text, the `orders` table, and the OFFSET are scenariolab schema
# knowledge -- exactly the kind of project-specific evidence the shared adapter
# must not hardcode. The shared adapter runs its three generic captures first,
# then calls this via run_lab_dependency_hook.
set -euo pipefail
# The shared adapter that invokes this hook exports PERFLAB_HARNESS_ROOT.
# shellcheck disable=SC1091
source "${PERFLAB_HARNESS_ROOT}/core/lib/common.sh"   # compose, pg_* config
artifact_dir="${1:?snapshot hook needs <artifact-dir>}"
mkdir -p "${artifact_dir}/dependencies"

compose exec -T "${pg_service}" psql -U "${pg_user}" -d "${pg_db}" -t -A -c \
  "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT id, created_at, total, status FROM orders WHERE customer_id=1 ORDER BY created_at DESC, id DESC OFFSET 2475 LIMIT 25" \
  > "${artifact_dir}/dependencies/postgres-order-plan.json"
