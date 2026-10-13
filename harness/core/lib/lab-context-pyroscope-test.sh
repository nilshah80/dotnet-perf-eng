#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "lab-context-pyroscope-test: $*" >&2; exit 1; }

# shellcheck source=/dev/null
. "${repo}/harness/core/lib/python.sh"
PYTHON="$(perflab_python)" || fail "a working Python 3 interpreter was not found (tried python3, python)"

# Remote + profiling without telemetry opt-in or URL must fail closed.
if out="$(PERFLAB_LAB=remote-example PERFLAB_CONTINUOUS_PROFILING=1 \
    bash -c 'source "'"${repo}/harness/core/lib/common.sh"'"' 2>&1)"; then
  fail "remote profiling without telemetry opt-in was accepted:\n${out}"
fi
printf '%s\n' "${out}" | grep -q 'PERFLAB_REMOTE_TELEMETRY=1' || fail "missing remote telemetry error"

# Remote + telemetry still requires an explicit Pyroscope URL.
if out="$(PERFLAB_LAB=remote-example PERFLAB_CONTINUOUS_PROFILING=1 PERFLAB_REMOTE_TELEMETRY=1 \
    PERFLAB_PROMETHEUS_URL=https://prom.example PERFLAB_TEMPO_URL=https://tempo.example \
    PERFLAB_LOKI_URL=https://loki.example PERFLAB_PROM_JOB_REGEX=api PERFLAB_SERVICE_NAME_REGEX=api \
    bash -c 'source "'"${repo}/harness/core/lib/common.sh"'"' 2>&1)"; then
  fail "remote profiling inherited a missing Pyroscope URL:\n${out}"
fi
printf '%s\n' "${out}" | grep -q 'PERFLAB_PYROSCOPE_URL' || fail "missing explicit Pyroscope URL error"

# Remote + URL still requires the deployed service identities.
if out="$(PERFLAB_LAB=remote-example PERFLAB_CONTINUOUS_PROFILING=1 PERFLAB_REMOTE_TELEMETRY=1 \
    PERFLAB_PROMETHEUS_URL=https://prom.example PERFLAB_TEMPO_URL=https://tempo.example \
    PERFLAB_LOKI_URL=https://loki.example PERFLAB_PROM_JOB_REGEX=api PERFLAB_SERVICE_NAME_REGEX=api \
    PERFLAB_PYROSCOPE_URL=https://pyroscope.example \
    bash -c 'source "'"${repo}/harness/core/lib/common.sh"'"' 2>&1)"; then
  fail "remote profiling without PERFLAB_PYROSCOPE_SERVICES was accepted:\n${out}"
fi
printf '%s\n' "${out}" | grep -q 'PERFLAB_PYROSCOPE_SERVICES' || fail "missing remote service identity error"

# Explicit remote Pyroscope URL + services still require read-only verification.
if out="$(PERFLAB_LAB=remote-example PERFLAB_CONTINUOUS_PROFILING=1 PERFLAB_REMOTE_TELEMETRY=1 \
    PERFLAB_PROMETHEUS_URL=https://prom.example PERFLAB_TEMPO_URL=https://tempo.example \
    PERFLAB_LOKI_URL=https://loki.example PERFLAB_PROM_JOB_REGEX=api PERFLAB_SERVICE_NAME_REGEX=api \
    PERFLAB_PYROSCOPE_URL=https://pyroscope.example PERFLAB_PYROSCOPE_SERVICES=checkout-api \
    bash -c 'source "'"${repo}/harness/core/lib/common.sh"'"' 2>&1)"; then
  fail "remote profiling without verification URL was accepted:\n${out}"
fi
printf '%s\n' "${out}" | grep -q 'PERFLAB_PROFILING_VERIFICATION_URL' || fail "missing verification URL error"

# The verification endpoint is FETCHED, so the test must serve a real document.
# A URL that merely exists is not evidence that the remote profiler is running,
# which is the whole point of D-P0-2.
verify_dir="$(mktemp -d "${TMPDIR:-/tmp}/perflab-verify.XXXXXX")"
trap 'rm -rf "${verify_dir}"; [[ -n "${verify_pid:-}" ]] && kill "${verify_pid}" 2>/dev/null' EXIT HUP INT TERM
cat > "${verify_dir}/profiling" <<'JSON'
{"provider":"pyroscope-dotnet","providerVersion":"1.5.1","activationProbe":"active","activeTypes":["cpu"],"verifiedAt":"2026-09-18T00:00:00Z"}
JSON
# An inline server rather than `python3 -m http.server 0`: the module buffers
# its "Serving HTTP on ... port N" banner, so the port cannot be read reliably.
"${PYTHON}" - "${verify_dir}" > "${verify_dir}/port" 2>"${verify_dir}/server.log" <<'PYSTUB' &
import http.server, socketserver, sys, threading
from pathlib import Path

root = Path(sys.argv[1])
document = (root / "profiling").read_bytes()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(document)))
        self.end_headers()
        self.wfile.write(document)
    def log_message(self, *_):
        pass

with socketserver.TCPServer(("127.0.0.1", 0), Handler) as server:
    print(server.server_address[1], flush=True)
    server.serve_forever()
PYSTUB
verify_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  verify_port="$(tr -d '[:space:]' < "${verify_dir}/port" 2>/dev/null || true)"
  [[ -n "${verify_port}" ]] && break
  sleep 0.5
done
[[ -n "${verify_port:-}" ]] || fail "verification stub did not report a port"

# Explicit remote endpoints, services, and verification source are accepted by context loading.
out="$(PERFLAB_LAB=remote-example PERFLAB_CONTINUOUS_PROFILING=1 PERFLAB_REMOTE_TELEMETRY=1 \
    PERFLAB_BACKEND_AUTHORIZATION='Bearer test-token' \
    PERFLAB_PROMETHEUS_URL=https://prom.example PERFLAB_TEMPO_URL=https://tempo.example \
    PERFLAB_LOKI_URL=https://loki.example PERFLAB_PROM_JOB_REGEX=api PERFLAB_SERVICE_NAME_REGEX=api \
    PERFLAB_PYROSCOPE_URL=https://pyroscope.example PERFLAB_PYROSCOPE_SERVICES=checkout-api \
    PERFLAB_PROFILING_VERIFICATION_URL="http://127.0.0.1:${verify_port}/profiling" \
    bash -c 'source "'"${repo}/harness/core/lib/common.sh"'"; printf "url=%s profiling=%s\n" "${pyroscope_url}" "${continuous_profiling}"' 2>&1)" \
  || fail "explicit remote Pyroscope URL was rejected:\n${out}"

printf '%s\n' "${out}" | grep -q 'url=https://pyroscope.example' || fail "pyroscope_url not recorded: ${out}"
printf '%s\n' "${out}" | grep -q 'profiling=1' || fail "continuous_profiling not set: ${out}"

# A profile type the remote agent does not list must be refused: an agent
# running cpu-only cannot substantiate an allocation finding.
if out="$(PERFLAB_LAB=remote-example PERFLAB_CONTINUOUS_PROFILING=1 PERFLAB_REMOTE_TELEMETRY=1 \
    PERFLAB_BACKEND_AUTHORIZATION='Bearer test-token' \
    PERFLAB_PROMETHEUS_URL=https://prom.example PERFLAB_TEMPO_URL=https://tempo.example \
    PERFLAB_LOKI_URL=https://loki.example PERFLAB_PROM_JOB_REGEX=api PERFLAB_SERVICE_NAME_REGEX=api \
    PERFLAB_PYROSCOPE_URL=https://pyroscope.example PERFLAB_PYROSCOPE_SERVICES=checkout-api \
    PERFLAB_PROFILING_TYPES=cpu,allocation \
    PERFLAB_PROFILING_VERIFICATION_URL="http://127.0.0.1:${verify_port}/profiling" \
    bash -c 'source "'"${repo}/harness/core/lib/common.sh"'"' 2>&1)"; then
  fail "an unverified profile type was accepted:\n${out}"
fi
printf '%s\n' "${out}" | grep -q "does not list profile type 'allocation'" || fail "unverified-type error text: ${out}"

# An invalid boolean is rejected before any lab work starts.
if out="$(PERFLAB_LAB=scenariolab PERFLAB_CONTINUOUS_PROFILING=maybe \
    bash -c 'source "'"${repo}/harness/core/lib/common.sh"'"' 2>&1)"; then
  fail "invalid PERFLAB_CONTINUOUS_PROFILING was accepted:\n${out}"
fi
printf '%s\n' "${out}" | grep -q 'must be 1/true or 0/false' || fail "invalid boolean error text: ${out}"

if out="$(PERFLAB_LAB=scenariolab PERFLAB_PROFILING_KEEP_TIERING=maybe \
    bash -c 'source "'"${repo}/harness/core/lib/common.sh"'"' 2>&1)"; then
  fail "invalid PERFLAB_PROFILING_KEEP_TIERING was accepted:\n${out}"
fi
printf '%s\n' "${out}" | grep -q 'PERFLAB_PROFILING_KEEP_TIERING must be 1/true or 0/false' || fail "invalid keep-tiering error text: ${out}"

# Local default remains loopback 4040.
out="$(PERFLAB_LAB=scenariolab PERFLAB_CONTINUOUS_PROFILING=0 \
    bash -c 'source "'"${repo}/harness/core/lib/common.sh"'"; printf "url=%s profiling=%s keep=%s\n" "${pyroscope_url}" "${continuous_profiling}" "${PERFLAB_PROFILING_KEEP_TIERING}"' 2>&1)" \
  || fail "local default failed:\n${out}"
printf '%s\n' "${out}" | grep -q 'url=http://127.0.0.1:4040' || fail "local default URL: ${out}"
printf '%s\n' "${out}" | grep -q 'profiling=0' || fail "local default profiling: ${out}"
printf '%s\n' "${out}" | grep -q 'keep=0' || fail "keep-tiering default: ${out}"

out="$(PERFLAB_LAB=scenariolab PERFLAB_PROFILING_KEEP_TIERING=true \
    bash -c 'source "'"${repo}/harness/core/lib/common.sh"'"; printf "keep=%s\n" "${PERFLAB_PROFILING_KEEP_TIERING}"' 2>&1)" \
  || fail "keep-tiering true was rejected:\n${out}"
printf '%s\n' "${out}" | grep -q 'keep=1' || fail "keep-tiering true was not exported as 1: ${out}"

scenariolab_keep="$(grep -c 'PERFLAB_PROFILING_KEEP_TIERING: ${PERFLAB_PROFILING_KEEP_TIERING:-0}' "${repo}/labs/scenariolab/compose.yaml" || true)"
[[ "${scenariolab_keep}" == "2" ]] || fail "scenariolab compose must forward keep-tiering on api and worker (got ${scenariolab_keep})"
ecommerce_keep="$(grep -c 'PERFLAB_PROFILING_KEEP_TIERING: ${PERFLAB_PROFILING_KEEP_TIERING:-0}' "${repo}/labs/ecommerce/compose.yaml" || true)"
[[ "${ecommerce_keep}" == "1" ]] || fail "ecommerce compose must forward keep-tiering on api (got ${ecommerce_keep})"

for managed_lab in scenariolab ecommerce; do
  out="$(PERFLAB_LAB="${managed_lab}" bash -c '
    source "'"${repo}"'/harness/core/lib/common.sh"
    source "'"${repo}"'/harness/core/lib/performance.sh"
    performance_profiling_preflight
  ' 2>&1)" || fail "${managed_lab} profiling preflight failed:\n${out}"
  printf '%s\n' "${out}" | grep -q '"captureState":"captured"' ||
    fail "${managed_lab} profiling preflight did not emit captured evidence: ${out}"
done

echo "lab-context pyroscope tests passed"
