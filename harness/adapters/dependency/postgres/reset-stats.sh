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

# pg_stat_database (deadlocks, commits, rollbacks) is cumulative for the
# database's lifetime and is not reset here. Record it instead, so a stack that
# served earlier runs can still report this run's measured-window counts.
artifact_dir="${1:-}"
if [[ -n "${artifact_dir}" ]]; then
  mkdir -p "${artifact_dir}/dependencies"
  compose exec -T "${pg_service}" psql -U "${pg_user}" -d "${pg_db}" -c \
    "COPY (SELECT datname, numbackends, xact_commit, xact_rollback, deadlocks FROM pg_stat_database WHERE datname='${pg_db}') TO STDOUT WITH CSV HEADER" \
    > "${artifact_dir}/dependencies/postgres-deadlocks-preload.csv" 2>/dev/null \
    || rm -f "${artifact_dir}/dependencies/postgres-deadlocks-preload.csv"
fi
