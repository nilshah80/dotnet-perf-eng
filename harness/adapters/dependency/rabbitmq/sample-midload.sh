#!/usr/bin/env bash
# rabbitmq dependency adapter -- live connection/channel sample mid-measurement.
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"
artifact_dir="${1:?sample-midload.sh <artifact-dir>}"
mkdir -p "${artifact_dir}/dependencies"
auth="${rabbit_user}:${RABBITMQ_PASSWORD:-perflab}"
curl -fsS --max-time 10 -u "${auth}" "${rabbit_mgmt_url}/api/connections" \
  > "${artifact_dir}/dependencies/rabbitmq-connections-midload.json" 2>/dev/null || true
curl -fsS --max-time 10 -u "${auth}" "${rabbit_mgmt_url}/api/channels" \
  > "${artifact_dir}/dependencies/rabbitmq-channels-midload.json" 2>/dev/null || true

run_lab_dependency_hook rabbitmq sample-midload "${artifact_dir}"
