#!/usr/bin/env bash
# Case 44: a real process restart is bracketed by target-owned measurement
# attestations. A subsequent window must contain only the replacement instance,
# never the stale pre-restart instance.
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
project="${root}/source/dotnet/protocol-reliability/ProtocolReliability.Api.csproj"
for tool in dotnet curl jq lsof; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "measurement-window-proof-test: ${tool} is required" >&2; exit 1; }
done

# Use the native product's exact bounded parser/probe implementation, with a
# host jq shim because this isolated target proof has no Compose dependency. The
# shim keeps common.sh's jqd guards: jq.exe writes CRLF on Windows, and MSYS
# rewrites POSIX-looking arguments such as `--arg path /api/...`.
# shellcheck disable=SC1091
source "${root}/harness/core/lib/performance.sh"
jqd() { MSYS_NO_PATHCONV=1 jq "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; }
target_curl() { curl "$@"; }
export PERFLAB_MEASUREMENT_WINDOW_PROBE_PATH=/api/reliability/window

work="$(mktemp -d "${TMPDIR:-/tmp}/protocol-measurement-window.XXXXXX")"
app_pid=""
cleanup() {
  [[ -z "${app_pid}" ]] || { kill "${app_pid}" 2>/dev/null || true; wait "${app_pid}" 2>/dev/null || true; }
  if [[ "${PERFLAB_WINDOW_KEEP:-0}" == "1" ]]; then
    echo "measurement-window-proof-test: retained diagnostic files at ${work}" >&2
  else
    rm -rf "${work}"
  fi
}
trap cleanup EXIT HUP INT TERM

port=""
for candidate in $(seq 18750 18789); do
  if ! lsof -n -iTCP:"${candidate}" -sTCP:LISTEN >/dev/null 2>&1 &&
     ! lsof -n -iTCP:"$((candidate + 100))" -sTCP:LISTEN >/dev/null 2>&1; then
    port="${candidate}"
    break
  fi
done
[[ -n "${port}" ]] || { echo "measurement-window-proof-test: no free test port" >&2; exit 1; }
base="http://127.0.0.1:${port}"

dotnet build "${project}" --no-restore --nologo >/dev/null
app_dll="${root}/source/dotnet/protocol-reliability/bin/Debug/net10.0/ProtocolReliability.Api.dll"
start_app() {
  local instance="$1"
  PERFLAB_HTTP_PORT="${port}" PERFLAB_GRPC_PORT="$((port + 100))" INSTANCE_ID="${instance}" \
    dotnet "${app_dll}" >"${work}/${instance}.log" 2>&1 &
  app_pid="$!"
  for _ in $(seq 1 30); do
    curl -fsS --max-time 2 "${base}/health/ready" >/dev/null 2>&1 && return 0
    sleep 1
  done
  cat "${work}/${instance}.log" >&2
  return 1
}

start_app before-restart
performance_measurement_window_probe "${base}" run-restart-proof mw-first start "${work}/first-start.json"
kill "${app_pid}"
wait "${app_pid}" 2>/dev/null || true
app_pid=""
start_app after-restart
performance_measurement_window_probe "${base}" run-restart-proof mw-first end "${work}/first-end.json"
performance_measurement_window_finalize "${work}/first-start.json" "${work}/first-end.json" "${work}/first-window.json"

# A new measurement run begins after the restart. Its start/end attestations
# must report only the new process generation, which is the stale-instance
# exclusion that telemetry range selection needs to preserve.
performance_measurement_window_probe "${base}" run-after-restart mw-second start "${work}/second-start.json"
curl -fsS -H 'X-Perf-Run-Id: run-after-restart' "${base}/api/reliability/status" >/dev/null
performance_measurement_window_probe "${base}" run-after-restart mw-second end "${work}/second-end.json"
performance_measurement_window_finalize "${work}/second-start.json" "${work}/second-end.json" "${work}/second-window.json"

jq -e '
  .restartDetected == true and
  (.instanceIds | sort == ["after-restart", "before-restart"]) and
  .scope == "exact-boundary-instance-set"
' "${work}/first-window.json" >/dev/null || {
  echo "measurement-window-proof-test: restart was not recorded as a two-instance first window" >&2
  exit 1
}
jq -e '
  .restartDetected == false and
  .instanceIds == ["after-restart"] and
  (.start.instanceId == "after-restart" and .end.instanceId == "after-restart")
' "${work}/second-window.json" >/dev/null || {
  echo "measurement-window-proof-test: stale pre-restart instance leaked into the next window" >&2
  exit 1
}

# A Compose recycle keeps INSTANCE_ID constant. The process start timestamp,
# rather than the service name alone, must distinguish the new generation.
performance_measurement_window_probe "${base}" run-same-name mw-third start "${work}/third-start.json"
kill "${app_pid}"
wait "${app_pid}" 2>/dev/null || true
app_pid=""
start_app after-restart
performance_measurement_window_probe "${base}" run-same-name mw-third end "${work}/third-end.json"
performance_measurement_window_finalize "${work}/third-start.json" "${work}/third-end.json" "${work}/third-window.json"
jq -e '
  .restartDetected == true and .instanceIds == ["after-restart"] and
  .start.processStartedAtUnixMilliseconds != .end.processStartedAtUnixMilliseconds
' "${work}/third-window.json" >/dev/null || {
  echo "measurement-window-proof-test: same-name process replacement was missed" >&2
  exit 1
}

echo "measurement-window proof passed: renamed and same-name restarts are explicit; stable generations stay stable"
