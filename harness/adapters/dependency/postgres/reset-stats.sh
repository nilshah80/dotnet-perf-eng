#!/usr/bin/env bash
# postgres dependency adapter -- reset ONLY the cumulative-since-reset statistics
# (pg_stat_statements), invoked AFTER warm-up so the statement snapshot in the
# evidence package covers the MEASURE phase rather than warm-up + measure. Touches
# no data and runs no lab hook, so a warm cache/dataset survives.
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"
compose exec -T "${pg_service}" \
  psql -U "${pg_user}" -d "${pg_db}" -c "SELECT pg_stat_statements_reset();" >/dev/null
