#!/usr/bin/env bash
# Gate B case 4b: execute the real .NET fixture and the real k6 asset. The
# checks prove that cookies carry the session, refresh is required and rotates,
# and a forged CSRF header cannot mutate state.
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
fail() { echo "security-journey-test: $*" >&2; exit 1; }
for command in dotnet curl jq k6; do
  command -v "${command}" >/dev/null || fail "${command} is required"
done
# shellcheck source=/dev/null
. "${root}/harness/core/lib/python.sh"
PYTHON="$(perflab_python)" || fail "a working Python 3 interpreter was not found (tried python3, python)"

project="${root}/source/dotnet/protocol-reliability/ProtocolReliability.Api.csproj"
[[ -f "${project}" ]] || fail "Protocol Reliability project is missing"
dotnet build "${project}" --no-restore --nologo >/dev/null || fail "target build failed"

http_port="$("${PYTHON}" - <<'PY'
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
)"
grpc_port="$("${PYTHON}" - <<'PY'
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
)"
# A native Windows Python writes "NNNN\r\n"; the CR would end up in every URL.
http_port="${http_port%$'\r'}"
grpc_port="${grpc_port%$'\r'}"
work="$(mktemp -d "${TMPDIR:-/tmp}/perflab-security-journey.XXXXXX")"
app_pid=""
cleanup() {
  if [[ -n "${app_pid}" ]]; then
    kill "${app_pid}" 2>/dev/null || true
    wait "${app_pid}" 2>/dev/null || true
  fi
  if [[ "${PERFLAB_TEST_KEEP:-0}" == "1" ]]; then
    echo "retained live evidence at ${work}" >&2
  else
  rm -rf "${work}"
  fi
}
trap cleanup EXIT HUP INT TERM

PERFLAB_HTTP_PORT="${http_port}" PERFLAB_GRPC_PORT="${grpc_port}" \
  dotnet run --project "${project}" --no-build --no-restore >"${work}/target.log" 2>&1 &
app_pid=$!
base="http://127.0.0.1:${http_port}"
for _ in $(seq 1 100); do
  if curl -fsS "${base}/health/ready" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
curl -fsS "${base}/health/ready" >/dev/null || fail "target did not become ready: $(tail -20 "${work}/target.log")"

# D-P1-7 target-owned remote correlation: this is not merely a static lab
# descriptor. The running target must echo the exact generated identity through
# the same request middleware that stamps metrics, logs, and request spans.
correlation="$(curl -fsS -H 'X-Perf-Run-Id: remote-correlation-proof' "${base}/api/reliability/correlation")"
printf '%s' "${correlation}" | jq -e \
  '.contractVersion == "perflab-run-id-v1" and .runId == "remote-correlation-proof" and (.instanceId | type == "string" and length > 0)' \
  >/dev/null || fail "target did not prove the remote run-id correlation contract"
missing_correlation="$(curl -sS -o "${work}/missing-correlation.json" -w '%{http_code}' "${base}/api/reliability/correlation")"
[[ "${missing_correlation}" == "400" ]] || fail "correlation endpoint accepted a missing run id"

jar="${work}/cookies.txt"
login="$(curl -fsS -c "${jar}" -X POST "${base}/api/reliability/journey/login")"
access="$(printf '%s' "${login}" | jq -er '.accessToken')"
refresh="$(printf '%s' "${login}" | jq -er '.refreshToken')"
form="$(curl -fsS -b "${jar}" "${base}/api/reliability/journey/form")"
csrf="$(printf '%s' "${form}" | jq -er '.csrfToken')"

status() {
  local destination="$1"; shift
  curl -sS -o "${destination}" -w '%{http_code}' "$@"
}
expired="$(status "${work}/expired.json" -b "${jar}" -H "Authorization: Bearer ${access}" "${base}/api/reliability/journey/protected")"
[[ "${expired}" == "401" && "$(jq -r '.error' "${work}/expired.json")" == "access-token-expired" ]] \
  || fail "initial access token did not require refresh"

rotated="$(curl -fsS -b "${jar}" -H 'Content-Type: application/json' \
  --data "{\"refreshToken\":\"${refresh}\"}" "${base}/api/reliability/journey/refresh")"
active="$(printf '%s' "${rotated}" | jq -er '.accessToken')"
rotated_csrf="$(printf '%s' "${rotated}" | jq -er '.csrfToken')"
[[ "${csrf}" != "${rotated_csrf}" ]] || fail "refresh did not rotate the CSRF token"

forged="$(status "${work}/forged.json" -b "${jar}" -X POST \
  -H "Authorization: Bearer ${active}" -H 'X-Perf-CSRF: forged' \
  "${base}/api/reliability/journey/submit")"
[[ "${forged}" == "403" && "$(jq -r '.error' "${work}/forged.json")" == "csrf-rejected" ]] \
  || fail "forged CSRF mutation was not refused"

submitted="$(status "${work}/submit.json" -b "${jar}" -X POST \
  -H "Authorization: Bearer ${active}" -H "X-Perf-CSRF: ${rotated_csrf}" \
  "${base}/api/reliability/journey/submit")"
[[ "${submitted}" == "201" && "$(jq -er '.submission' "${work}/submit.json")" == "1" ]] \
  || fail "valid cookie/token/CSRF mutation did not complete once"

replay="$(status "${work}/replay.json" -b "${jar}" -H 'Content-Type: application/json' \
  --data "{\"refreshToken\":\"${refresh}\"}" "${base}/api/reliability/journey/refresh")"
[[ "${replay}" == "401" && "$(jq -r '.error' "${work}/replay.json")" == "refresh-rejected" ]] \
  || fail "used refresh token was accepted"

PERF_BASE_URL="${base}" PERF_RUN_ID="security-journey-proof" PERF_SCENARIO=P12 \
  PERF_PARTITION_READY=1 PERF_WRITE_ACK=managed-reference PERF_WRITE_BUDGET=1 \
  k6 run --vus 1 --iterations 1 --quiet --no-color \
    --summary-export "${work}/k6-summary.json" \
    "${root}/labs/protocol-reliability/loadgen/journey.js" >/dev/null

jq -e '
  (.metrics.journey_completed.count == 1) and
  (.metrics.journey_wire_requests.count == 7) and
  ((.metrics.journey_request_failures.count // 0) == 0) and
  ((.metrics.journey_transport_errors.count // 0) == 0) and
  ((.metrics.journey_status_errors.count // 0) == 0)
' "${work}/k6-summary.json" >/dev/null \
  || fail "k6 did not report one clean security journey with seven wire attempts"

echo "security journey passed: remote run-id contract, cookie session, required refresh rotation, CSRF refusal, and one protected mutation"
