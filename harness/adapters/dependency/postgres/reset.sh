#!/usr/bin/env bash
# postgres dependency adapter -- reset before load so the run is scenario-scoped.
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"
artifact_dir="${1:-}"
# Restore the seeded rows first (see restore-seed.sql), then reset the statement
# statistics so the restore's own statements are not counted.
compose exec -T "${pg_service}" \
  psql -X -q -v ON_ERROR_STOP=1 -U "${pg_user}" -d "${pg_db}" \
  < "${HARNESS_ROOT}/adapters/dependency/postgres/restore-seed.sql" >/dev/null
compose exec -T "${pg_service}" \
  psql -U "${pg_user}" -d "${pg_db}" -c "SELECT pg_stat_statements_reset();" >/dev/null

run_lab_dependency_hook postgres reset "${artifact_dir}"
