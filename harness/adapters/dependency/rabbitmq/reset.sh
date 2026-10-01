#!/usr/bin/env bash
# rabbitmq dependency adapter -- reset before load: purge the lab queues.
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

# The cumulative baselines (per-queue message_stats, broker connections and
# channels opened) are NOT taken here. This runs before warm-up, and warm-up
# publishes real traffic -- a baseline taken now counts warm-up work as measured
# work, while the HTTP side counts the measure phase alone. They are taken in
# reset-stats.sh, after warm-up.

run_lab_dependency_hook rabbitmq reset "${artifact_dir}"
