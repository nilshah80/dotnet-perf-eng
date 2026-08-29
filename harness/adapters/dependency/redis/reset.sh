#!/usr/bin/env bash
# redis dependency adapter -- reset before load. FLUSHALL clears keys but not
# INFO counters, so CONFIG RESETSTAT is what makes keyspace_hits/misses
# scenario-scoped rather than cumulative for the container's lifetime.
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"
compose exec -T redis redis-cli FLUSHALL >/dev/null
compose exec -T redis redis-cli CONFIG RESETSTAT >/dev/null
