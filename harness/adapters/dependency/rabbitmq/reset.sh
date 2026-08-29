#!/usr/bin/env bash
# rabbitmq dependency adapter -- reset before load: purge the lab queues and
# baseline the broker's cumulative opened/closed counters, so churn during the
# run is a difference rather than an absolute carrying every earlier scenario.
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"
artifact_dir="${1:?reset.sh <artifact-dir>}"
mkdir -p "${artifact_dir}/dependencies"

compose exec -T rabbitmq rabbitmqctl purge_queue perf.orders.created >/dev/null 2>&1 || true
compose exec -T rabbitmq rabbitmqctl purge_queue perf.orders.dead    >/dev/null 2>&1 || true

curl -fsS --max-time 15 http://127.0.0.1:15692/metrics 2>/dev/null \
  | grep -E '^rabbitmq_(connections|channels)' \
  > "${artifact_dir}/dependencies/rabbitmq-broker-metrics-preload.txt" || true
