#!/usr/bin/env bash
# redis dependency adapter -- live client sample taken mid-measurement.
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"
artifact_dir="${1:?sample-midload.sh <artifact-dir>}"
mkdir -p "${artifact_dir}/dependencies"
fail=0
compose exec -T "${redis_service}" redis-cli INFO clients \
  > "${artifact_dir}/dependencies/redis-clients-midload.txt" 2>/dev/null || fail=1

run_lab_dependency_hook redis sample-midload "${artifact_dir}" || fail=1
# Exit non-zero if any capture failed so the parent's (non-fatal) mid-load warning
# fires; mid-load evidence is best-effort, so this does NOT mark the package partial.
exit "${fail}"
