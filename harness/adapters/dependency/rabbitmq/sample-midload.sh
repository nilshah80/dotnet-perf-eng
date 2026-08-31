#!/usr/bin/env bash
# rabbitmq dependency adapter -- live connection/channel sample mid-measurement.
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"
artifact_dir="${1:?sample-midload.sh <artifact-dir>}"
mkdir -p "${artifact_dir}/dependencies"
auth="${rabbit_user}:${RABBITMQ_PASSWORD:-perflab}"
fail=0
curl -fsS --max-time 10 -u "${auth}" "${rabbit_mgmt_url}/api/connections" \
  > "${artifact_dir}/dependencies/rabbitmq-connections-midload.json" 2>/dev/null || fail=1
curl -fsS --max-time 10 -u "${auth}" "${rabbit_mgmt_url}/api/channels" \
  > "${artifact_dir}/dependencies/rabbitmq-channels-midload.json" 2>/dev/null || fail=1

run_lab_dependency_hook rabbitmq sample-midload "${artifact_dir}" || fail=1
# Exit non-zero if any capture failed so the parent's (non-fatal) mid-load warning
# fires; mid-load evidence is best-effort, so this does NOT mark the package partial.
exit "${fail}"
