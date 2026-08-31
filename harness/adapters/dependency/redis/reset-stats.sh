#!/usr/bin/env bash
# redis dependency adapter -- reset ONLY the cumulative statistics (INFO stat
# counters, slowlog, latency events) AFTER warm-up so those snapshots cover the
# MEASURE phase. Deliberately does NOT FLUSHALL: the warm keyspace must survive
# (clearing it here would turn a warmed-cache measurement into a cold one).
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"
compose exec -T "${redis_service}" redis-cli CONFIG RESETSTAT >/dev/null
compose exec -T "${redis_service}" redis-cli SLOWLOG RESET >/dev/null
compose exec -T "${redis_service}" redis-cli LATENCY RESET >/dev/null
