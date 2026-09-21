#!/usr/bin/env bash
# Case 38: a real 429 from the bounded target queue must be recorded as an
# application rejection, while an unreachable endpoint must be transport
# failure. The same declared k6 workload is used for both conditions.
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
project="${root}/source/dotnet/protocol-reliability/ProtocolReliability.Api.csproj"
script="${root}/labs/protocol-reliability/loadgen/k6.js"
for tool in dotnet k6 curl jq lsof; do command -v "${tool}" >/dev/null 2>&1 || { echo "backpressure-proof-test: ${tool} is required" >&2; exit 1; }; done
work="$(mktemp -d "${TMPDIR:-/tmp}/protocol-backpressure.XXXXXX")"
app_pid=""
cleanup() {
  [[ -z "${app_pid}" ]] || { kill "${app_pid}" 2>/dev/null || true; wait "${app_pid}" 2>/dev/null || true; }
  if [[ "${PERFLAB_BACKPRESSURE_KEEP:-0}" == "1" ]]; then
    echo "backpressure-proof-test: retained diagnostic files at ${work}" >&2
  else
    rm -rf "${work}"
  fi
}
trap cleanup EXIT HUP INT TERM
port=""
for candidate in $(seq 18600 18639); do
  if ! lsof -n -iTCP:"${candidate}" -sTCP:LISTEN >/dev/null 2>&1; then port="${candidate}"; break; fi
done
[[ -n "${port}" ]] || { echo "backpressure-proof-test: no free test port" >&2; exit 1; }

dotnet build "${project}" --no-restore --nologo >/dev/null
PERFLAB_HTTP_PORT="${port}" PERFLAB_GRPC_PORT="$((port + 100))" QUEUE_CAPACITY=4 PERF_RUN_ID=backpressure-proof \
  dotnet "${root}/source/dotnet/protocol-reliability/bin/Debug/net10.0/ProtocolReliability.Api.dll" >"${work}/app.log" 2>&1 &
app_pid="$!"
for _ in $(seq 1 30); do
  if curl -fsS --max-time 2 "http://127.0.0.1:${port}/health/ready" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS -X POST -H 'X-Perf-Admin: protocol-reliability-local' \
  "http://127.0.0.1:${port}/api/reliability/control?paused=true&delayMs=5000" >/dev/null

PERF_BASE_URL="http://127.0.0.1:${port}" PERF_METHOD=POST PERF_PATH='/api/reliability/messages?tenant=backpressure' \
PERF_BODY='{}' PERF_RUN_ID=backpressure-proof \
  k6 run --vus 16 --iterations 64 --summary-export "${work}/rejection-summary.json" "${script}" >/dev/null
jq -e '
  (.metrics.reliability_expected_backpressure.count // 0) > 0 and
  (.metrics.reliability_transport_errors.count // 0) == 0
' "${work}/rejection-summary.json" >/dev/null \
  || { echo "backpressure-proof-test: a local 429/503 was not distinguished from transport failure" >&2; exit 1; }

set +e
PERF_BASE_URL='http://127.0.0.1:1' PERF_METHOD=POST PERF_PATH='/api/reliability/messages?tenant=backpressure' \
PERF_BODY='{}' PERF_RUN_ID=backpressure-transport-proof \
  k6 run --vus 1 --iterations 1 --summary-export "${work}/transport-summary.json" "${script}" >/dev/null 2>&1
transport_rc=$?
set -e
[[ -s "${work}/transport-summary.json" ]] || { echo "backpressure-proof-test: unreachable target produced no k6 summary (exit ${transport_rc})" >&2; exit 1; }
jq -e '
  (.metrics.reliability_transport_errors.count // 0) > 0 and
  (.metrics.reliability_expected_backpressure.count // 0) == 0
' "${work}/transport-summary.json" >/dev/null \
  || { echo "backpressure-proof-test: transport failure was not recorded separately" >&2; exit 1; }

echo "backpressure proof passed: bounded-queue rejection and unreachable transport failure are separate k6 evidence states"
