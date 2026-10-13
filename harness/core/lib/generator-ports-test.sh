#!/usr/bin/env bash
# Generator TIME_WAIT is counted toward the run's own target endpoints only.
# Counting every TIME_WAIT toward the target host included the target's server
# side and every other local service (Prometheus, Pyroscope, the monitors), which
# could report generator port exhaustion that did not happen.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "generator-ports-test: $*" >&2; exit 1; }
work="$(mktemp -d "${TMPDIR:-/tmp}/generator-ports-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT HUP INT TERM
export PERFLAB_JQ=host PERFLAB_LAB_OPTIONAL=1
# shellcheck disable=SC1091
source "${repo}/harness/core/lib/common.sh"
# shellcheck disable=SC1091
source "${repo}/harness/core/lib/performance.sh"

endpoints="$(PERF_GRPC_TARGET=127.0.0.1:18081 performance_generator_endpoints http://localhost:18080/api)"
[[ "${endpoints}" == "127.0.0.1:18080 127.0.0.1:18081" ]] || fail "endpoints: ${endpoints}"
[[ "$(performance_generator_endpoints https://[::1]/x)" == "127.0.0.1:443" ]] || fail "default https port or IPv6 loopback"

# macOS netstat and Linux ss rows: two client-side sockets toward 18080 and one
# toward the gRPC port count; the target's own server side and Prometheus do not.
cat > "${work}/sockets" <<'ROWS'
tcp4 0 0 127.0.0.1.51000 127.0.0.1.18080 TIME_WAIT
tcp4 0 0 127.0.0.1.18080 127.0.0.1.51001 TIME_WAIT
tcp4 0 0 127.0.0.1.51002 127.0.0.1.9090 TIME_WAIT
tcp6 0 0 ::1.51003 ::1.18081 TIME_WAIT
TIME-WAIT 0 0 127.0.0.1:51004 127.0.0.1:18080
ROWS
netstat() { cat "${work}/sockets"; }
count="$(performance_generator_time_wait "${endpoints}")"
[[ "${count}" == 3 ]] || fail "counted ${count} TIME_WAIT sockets toward ${endpoints}, want 3"

# After a warm-up that churned connections (P02), measurement waits until the
# target answers again, and records the wait; a target that never answers is
# recorded as not ready rather than waited on without bound.
printf 'tcp4 0 0 127.0.0.1.51000 127.0.0.1.9090 TIME_WAIT\n' > "${work}/sockets"
printf '{"schemaVersion":"generator-ports-v1","state":"clear"}\n' > "${work}/ports.json"
probes=0
target_curl() { probes=$((probes + 1)); (( probes >= 3 )); }
performance_generator_recover "${endpoints}" http://127.0.0.1:18080/health "${work}/ports.json" 2>/dev/null
jq -e '.state == "clear" and .afterWarmup.targetReady == true and .afterWarmup.waitedSeconds == 2 and .afterWarmup.timeWaitAtStart == 0' "${work}/ports.json" >/dev/null \
  || fail "the recovery after warm-up was not recorded: $(cat "${work}/ports.json")"
target_curl() { return 7; }
PERFLAB_GENERATOR_SETTLE_SECONDS=1 performance_generator_recover "${endpoints}" http://127.0.0.1:18080/health "${work}/ports.json" 2> "${work}/recover.err"
jq -e '.afterWarmup.targetReady == false and .afterWarmup.waitedSeconds == 1' "${work}/ports.json" >/dev/null \
  || fail "a target that never answered was not recorded: $(cat "${work}/ports.json")"
grep -q "did not answer" "${work}/recover.err" || fail "a target that never answered was not reported"

echo "generator ports tests passed"
