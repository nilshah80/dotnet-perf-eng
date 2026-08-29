#!/usr/bin/env bash
# redis dependency adapter -- post-run snapshot for the evidence package.
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"
artifact_dir="${1:?snapshot.sh <artifact-dir>}"
dep="${artifact_dir}/dependencies"; mkdir -p "${dep}"
compose exec -T "${redis_service}" redis-cli INFO all       > "${dep}/redis-info.txt"
compose exec -T "${redis_service}" redis-cli SLOWLOG GET 128 > "${dep}/redis-slowlog.txt"
compose exec -T "${redis_service}" redis-cli LATENCY LATEST  > "${dep}/redis-latency.txt"

run_lab_dependency_hook redis snapshot "${artifact_dir}"
