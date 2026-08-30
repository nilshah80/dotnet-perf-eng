#!/usr/bin/env bash
# rabbitmq dependency adapter -- post-run snapshot for the evidence package.
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"
artifact_dir="${1:?snapshot.sh <artifact-dir>}"
dep="${artifact_dir}/dependencies"; mkdir -p "${dep}"
auth="${rabbit_user}:${RABBITMQ_PASSWORD:-perflab}"

curl -fsS --max-time 15 -u "${auth}" "${rabbit_mgmt_url}/api/queues"      > "${dep}/rabbitmq-queues.json" || true
curl -fsS --max-time 15 -u "${auth}" "${rabbit_mgmt_url}/api/connections" > "${dep}/rabbitmq-connections.json" || true
curl -fsS --max-time 15 -u "${auth}" "${rabbit_mgmt_url}/api/channels"    > "${dep}/rabbitmq-channels.json" || true
curl -fsS --max-time 15 "${rabbit_metrics_url}" 2>/dev/null \
  | grep -E '^rabbitmq_(connections|channels)' \
  > "${dep}/rabbitmq-broker-metrics.txt" || true

run_lab_dependency_hook rabbitmq snapshot "${artifact_dir}"
