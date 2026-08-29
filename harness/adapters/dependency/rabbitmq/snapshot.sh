#!/usr/bin/env bash
# rabbitmq dependency adapter -- post-run snapshot for the evidence package.
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"
artifact_dir="${1:?snapshot.sh <artifact-dir>}"
dep="${artifact_dir}/dependencies"; mkdir -p "${dep}"
auth="perflab:${RABBITMQ_PASSWORD:-perflab}"

curl -fsS --max-time 15 -u "${auth}" http://127.0.0.1:15672/api/queues      > "${dep}/rabbitmq-queues.json" || true
curl -fsS --max-time 15 -u "${auth}" http://127.0.0.1:15672/api/connections > "${dep}/rabbitmq-connections.json" || true
curl -fsS --max-time 15 -u "${auth}" http://127.0.0.1:15672/api/channels    > "${dep}/rabbitmq-channels.json" || true
curl -fsS --max-time 15 http://127.0.0.1:15692/metrics 2>/dev/null \
  | grep -E '^rabbitmq_(connections|channels)' \
  > "${dep}/rabbitmq-broker-metrics.txt" || true
