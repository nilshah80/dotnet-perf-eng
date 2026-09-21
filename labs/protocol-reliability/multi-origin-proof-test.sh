#!/usr/bin/env bash
# Case 20: execute the third lab's declared P13 journey against two real
# listener origins, then prove a hostile secondary origin fails in k6 init
# before a request reaches a separately running sink target.
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
project="${root}/source/dotnet/protocol-reliability/ProtocolReliability.Api.csproj"
script="${root}/labs/protocol-reliability/loadgen/multi-origin.js"
for tool in dotnet k6 curl jq lsof; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "multi-origin-proof-test: ${tool} is required" >&2; exit 1; }
done

work="$(mktemp -d "${TMPDIR:-/tmp}/protocol-multi-origin.XXXXXX")"
app_pid=""
sink_pid=""
cleanup() {
  for pid in "${app_pid}" "${sink_pid}"; do
    [[ -z "${pid}" ]] || { kill "${pid}" 2>/dev/null || true; wait "${pid}" 2>/dev/null || true; }
  done
  if [[ "${PERFLAB_MULTI_ORIGIN_KEEP:-0}" == "1" ]]; then
    echo "multi-origin-proof-test: retained diagnostic files at ${work}" >&2
  else
    rm -rf "${work}"
  fi
}
trap cleanup EXIT HUP INT TERM

primary_port=""
for candidate in $(seq 18700 18739); do
  secondary_candidate=$((candidate + 1))
  sink_candidate=$((candidate + 2))
  if ! lsof -n -iTCP:"${candidate}" -sTCP:LISTEN >/dev/null 2>&1 &&
     ! lsof -n -iTCP:"${secondary_candidate}" -sTCP:LISTEN >/dev/null 2>&1 &&
     ! lsof -n -iTCP:"${sink_candidate}" -sTCP:LISTEN >/dev/null 2>&1 &&
     ! lsof -n -iTCP:"$((candidate + 100))" -sTCP:LISTEN >/dev/null 2>&1 &&
     ! lsof -n -iTCP:"$((candidate + 102))" -sTCP:LISTEN >/dev/null 2>&1; then
    primary_port="${candidate}"
    break
  fi
done
[[ -n "${primary_port}" ]] || { echo "multi-origin-proof-test: no free test port set" >&2; exit 1; }
secondary_port=$((primary_port + 1))
sink_port=$((primary_port + 2))

dotnet build "${project}" --no-restore --nologo >/dev/null
app_dll="${root}/source/dotnet/protocol-reliability/bin/Debug/net10.0/ProtocolReliability.Api.dll"

PERFLAB_HTTP_PORT="${primary_port}" \
PERFLAB_HTTP_SECONDARY_PORT="${secondary_port}" \
PERFLAB_GRPC_PORT="$((primary_port + 100))" \
INSTANCE_ID=multi-origin-allowed \
  dotnet "${app_dll}" >"${work}/allowed.log" 2>&1 &
app_pid="$!"
PERFLAB_HTTP_PORT="${sink_port}" \
PERFLAB_GRPC_PORT="$((primary_port + 102))" \
INSTANCE_ID=multi-origin-unallowed-sink \
  dotnet "${app_dll}" >"${work}/sink.log" 2>&1 &
sink_pid="$!"

wait_ready() {
  local base="$1"
  for _ in $(seq 1 30); do
    curl -fsS --max-time 2 "${base}/health/ready" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "multi-origin-proof-test: target did not become ready: ${base}" >&2
  return 1
}
primary="http://127.0.0.1:${primary_port}"
secondary="http://127.0.0.1:${secondary_port}"
sink="http://127.0.0.1:${sink_port}"
wait_ready "${primary}"
wait_ready "${secondary}"
wait_ready "${sink}"

allowed_origins="$(jq -cn --arg primary "${primary}" --arg secondary "${secondary}" '[$primary,$secondary]')"
PERF_ALLOWED_ORIGINS="${allowed_origins}" \
PERF_BASE_URL="${primary}" \
PERF_SECONDARY_BASE_URL="${secondary}" \
PERF_RUN_ID=multi-origin-proof \
  k6 run --quiet --vus 1 --iterations 1 --summary-export "${work}/allowed-summary.json" "${script}" >/dev/null
jq -e '
  (.metrics.journey_completed.count // 0) == 1 and
  (.metrics.journey_failed.count // 0) == 0 and
  (.metrics.multi_origin_primary_requests.count // 0) == 1 and
  (.metrics.multi_origin_secondary_requests.count // 0) == 1
' "${work}/allowed-summary.json" >/dev/null || {
  echo "multi-origin-proof-test: allowed two-origin journey did not complete exactly once" >&2
  exit 1
}

# A /status response snapshots before its own middleware increment. The second
# read should therefore be exactly one higher (the read itself), proving the
# rejected k6 initialization never reached the unallowed sink.
sink_before="$(curl -fsS "${sink}/api/reliability/status" | jq -r '.httpRequests')"
set +e
PERF_ALLOWED_ORIGINS="${allowed_origins}" \
PERF_BASE_URL="${primary}" \
PERF_SECONDARY_BASE_URL="${sink}" \
PERF_RUN_ID=multi-origin-hostile \
  k6 run --quiet --vus 1 --iterations 1 "${script}" >"${work}/hostile.out" 2>&1
hostile_rc=$?
set -e
[[ "${hostile_rc}" -ne 0 ]] || { echo "multi-origin-proof-test: hostile origin was accepted" >&2; exit 1; }
grep -q 'not in PERF_ALLOWED_ORIGINS' "${work}/hostile.out" || {
  echo "multi-origin-proof-test: hostile failure did not identify the allowlist boundary" >&2
  cat "${work}/hostile.out" >&2
  exit 1
}
sink_after="$(curl -fsS "${sink}/api/reliability/status" | jq -r '.httpRequests')"
[[ "${sink_after}" == "$((sink_before + 1))" ]] || {
  echo "multi-origin-proof-test: rejected origin received traffic (before=${sink_before}, after=${sink_after})" >&2
  exit 1
}

echo "multi-origin proof passed: P13 used exactly two allowlisted listener origins and rejected a hostile origin before traffic"
