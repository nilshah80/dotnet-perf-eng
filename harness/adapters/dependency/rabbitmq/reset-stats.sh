#!/usr/bin/env bash
# rabbitmq dependency adapter -- baseline cumulative counters AFTER warm-up.
#
# message_stats.publish/ack/redeliver are cumulative for the broker's lifetime,
# and purging a queue does not reset them. The accepted-versus-completed
# reconciliation subtracts this baseline, so when it is taken decides which
# traffic the reconciliation describes.
#
# It belongs here rather than in reset.sh because reset.sh runs BEFORE warm-up:
# a baseline taken there counts warm-up publishes as measured work, while the
# HTTP side counts the measure phase only -- so the two halves of the
# reconciliation describe different windows and the balance is meaningless.
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"
artifact_dir="${1:?reset-stats.sh <artifact-dir>}"
mkdir -p "${artifact_dir}/dependencies"

curl -fsS --max-time 15 -u "${rabbit_user}:${RABBITMQ_PASSWORD:-perflab}" "${rabbit_mgmt_url}/api/queues" \
  > "${artifact_dir}/dependencies/rabbitmq-queues-preload.json" \
  || {
    echo "WARNING: rabbitmq post-warm-up queue baseline failed; async reconciliation will report itself unscoped." >&2
    rm -f "${artifact_dir}/dependencies/rabbitmq-queues-preload.json"
  }
# Node uptime with the baseline: a broker that restarts during the window starts
# message_stats from zero, and the reconciliation must know its baseline is void.
nodes="$(curl -fsS --max-time 15 -u "${rabbit_user}:${RABBITMQ_PASSWORD:-perflab}" "${rabbit_mgmt_url}/api/nodes" 2>/dev/null)" \
  && printf '{"capturedAtEpoch":%s,"nodes":%s}\n' "$(date -u +%s)" "${nodes}" \
    > "${artifact_dir}/dependencies/rabbitmq-nodes-preload.json" || true

run_lab_dependency_hook rabbitmq reset-stats "${artifact_dir}"
