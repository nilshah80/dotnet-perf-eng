#!/usr/bin/env bash
# redis dependency adapter -- content fingerprint of the prepared cache state.
#
# Key count per database. A cache that was not cleared carries results from the
# previous run, and a scenario measuring cache-miss cost over a warm cache
# measures something else entirely.
set -euo pipefail
# Failures are NOT suppressed. A fingerprint that silently returns nothing is
# indistinguishable from an empty dataset, and the caller would hash the empty
# result and call the dataset identified.
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"

compose exec -T "${redis_service}" redis-cli DBSIZE | tr -d '\r'
