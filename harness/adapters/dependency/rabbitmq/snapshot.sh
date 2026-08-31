#!/usr/bin/env bash
# rabbitmq dependency adapter -- post-run snapshot for the evidence package.
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"
artifact_dir="${1:?snapshot.sh <artifact-dir>}"
dep="${artifact_dir}/dependencies"; mkdir -p "${dep}"
auth="${rabbit_user}:${RABBITMQ_PASSWORD:-perflab}"

# Track failures instead of swallowing them: a failed management-API capture
# (broker unreachable, wrong password) must surface so capture-evidence marks the
# package partial rather than "captured" with empty files.
fail=0
curl -fsS --max-time 15 -u "${auth}" "${rabbit_mgmt_url}/api/queues"      > "${dep}/rabbitmq-queues.json"      || { echo "WARNING: rabbitmq queues capture failed." >&2; fail=1; }
curl -fsS --max-time 15 -u "${auth}" "${rabbit_mgmt_url}/api/connections" > "${dep}/rabbitmq-connections.json" || { echo "WARNING: rabbitmq connections capture failed." >&2; fail=1; }
curl -fsS --max-time 15 -u "${auth}" "${rabbit_mgmt_url}/api/channels"    > "${dep}/rabbitmq-channels.json"    || { echo "WARNING: rabbitmq channels capture failed." >&2; fail=1; }
# Broker metrics are best-effort: the Prometheus plugin may be disabled, so an
# empty result here is not a capture failure.
curl -fsS --max-time 15 "${rabbit_metrics_url}" 2>/dev/null \
  | grep -E '^rabbitmq_(connections|channels)' \
  > "${dep}/rabbitmq-broker-metrics.txt" || true

run_lab_dependency_hook rabbitmq snapshot "${artifact_dir}" || fail=1
exit "${fail}"
