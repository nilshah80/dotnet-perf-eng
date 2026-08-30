#!/usr/bin/env bash
# postgres dependency adapter -- live sample taken mid-measurement, when pool
# usage and connection state are at their peak (invisible once load stops).
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"
artifact_dir="${1:?sample-midload.sh <artifact-dir>}"
mkdir -p "${artifact_dir}/dependencies"
compose exec -T "${pg_service}" psql -U "${pg_user}" -d "${pg_db}" -c \
  "COPY (SELECT application_name, state, count(*) AS connections FROM pg_stat_activity WHERE datname='${pg_db}' GROUP BY application_name, state ORDER BY application_name, state) TO STDOUT WITH CSV HEADER" \
  > "${artifact_dir}/dependencies/postgres-connections-midload.csv" 2>/dev/null || true

run_lab_dependency_hook postgres sample-midload "${artifact_dir}"
