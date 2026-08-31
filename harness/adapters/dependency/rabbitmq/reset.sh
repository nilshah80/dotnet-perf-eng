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

# Queue names are project-specific, declared as PERFLAB_RABBIT_QUEUES in
# lab.config.sh; a lab that declares none purges nothing here.
for q in ${rabbit_queues}; do
  compose exec -T "${rabbit_service}" rabbitmqctl purge_queue "${q}" >/dev/null 2>&1 || true
done

curl -fsS --max-time 15 "${rabbit_metrics_url}" 2>/dev/null \
  | grep -E '^rabbitmq_(connections|channels)' \
  > "${artifact_dir}/dependencies/rabbitmq-broker-metrics-preload.txt" || true

run_lab_dependency_hook rabbitmq reset "${artifact_dir}"
