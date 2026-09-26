#!/usr/bin/env bash
# Staged-profile conclusions (Gate A cases 11 and 12) from per-stage evidence.
#
#   11  a breakpoint names its last healthy and first failing level, and the
#       level beyond which throughput stopped following the load
#   12  a spike names its baseline, its surge degradation and the seconds until
#       p99 and errors were back at the baseline
#
# A fake Prometheus answers each windowed query from a table keyed by the query's
# evaluation time, so the stage windows the analyzer derives from the executed
# k6 schedule are part of what is tested.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "analyze-stages-test: $*" >&2; exit 1; }

# shellcheck source=/dev/null
. "${repo}/harness/core/lib/python.sh"
PYTHON="$(perflab_python)" || fail "a working Python 3 interpreter was not found (tried python3, python)"
jq_bin="$(command -v jq || true)"; [[ -n "${jq_bin}" ]] || fail "jq is required"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/analyze-stages-test.XXXXXX")"
server_pid=""
cleanup() {
  [[ -n "${server_pid}" ]] && { kill "${server_pid}" 2>/dev/null || true; wait "${server_pid}" 2>/dev/null || true; }
  [[ "${PERFLAB_TEST_KEEP:-0}" == "1" ]] && { echo "fixture kept at ${test_root}" >&2; return 0; }
  rm -rf "${test_root}"
}
trap cleanup EXIT HUP INT TERM
mkdir -p "${test_root}/bin"

# jqd() shells out to dockerized jq; use the local binary instead.
cat > "${test_root}/bin/docker" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ "\${1:-}" == "run" ]] || exit 0
shift
while [[ \$# -gt 0 ]]; do
  case "\$1" in --rm|--interactive|-i|-t|--tty) shift ;; *) break ;; esac
done
shift
exec "${jq_bin}" "\$@"
EOF
chmod +x "${test_root}/bin/docker"

spike_start=1800000000
break_start=1800001000
# Absolute evaluation time -> {rps, p99 (ms), bad (5xx/s)}. Unlisted times answer
# the default (1000 rps, 20 ms, no errors).
cat > "${test_root}/values.json" <<JSON
{
  "$((spike_start + 20))": {"rps": 1000, "p99": 20,  "bad": 0},
  "$((spike_start + 40))": {"rps": 1000, "p99": 300, "bad": 50},
  "$((spike_start + 50))": {"rps": 1000, "p99": 200, "bad": 20},
  "$((spike_start + 55))": {"rps": 1000, "p99": 22,  "bad": 0},
  "$((break_start + 15))": {"rps": 1000, "p99": 10,  "bad": 0},
  "$((break_start + 30))": {"rps": 2000, "p99": 20,  "bad": 0},
  "$((break_start + 45))": {"rps": 2050, "p99": 80,  "bad": 102.5},
  "$((break_start + 60))": {"rps": 1900, "p99": 90,  "bad": 0}
}
JSON
cat > "${test_root}/backend.py" <<'PY'
import http.server, json, sys, urllib.parse
values = json.load(open(sys.argv[1]))
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        promql = query.get("query", [""])[0]
        at = query.get("time", ["0"])[0].split(".")[0]
        row = values.get(at, {"rps": 1000, "p99": 20, "bad": 0})
        if "histogram_quantile" in promql:
            value = row["p99"]
        elif "http_response_status_code" in promql:
            value = row["bad"]
        else:
            value = row["rps"]
        body = {"status": "success", "data": {"resultType": "vector",
                "result": [{"metric": {}, "value": [float(at), str(value)]}]}}
        payload = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY
"${PYTHON}" "${test_root}/backend.py" "${test_root}/values.json" > "${test_root}/port" 2> "${test_root}/backend.err" &
server_pid=$!
for _ in $(seq 1 100); do
  [[ -s "${test_root}/port" ]] && break
  kill -0 "${server_pid}" 2>/dev/null || break
  sleep 0.1
done
[[ -s "${test_root}/port" ]] || { cat "${test_root}/backend.err" >&2; fail "fake backend did not report a port"; }
read -r port < "${test_root}/port"
port="${port%$'\r'}"
base="http://127.0.0.1:${port}"

lab_config="${test_root}/lab/lab.config.sh"
mkdir -p "${test_root}/lab"
sed -e "s|^PERFLAB_PROMETHEUS_URL=.*|PERFLAB_PROMETHEUS_URL=\"${base}\"|" \
  "${repo}/labs/ecommerce/lab.config.sh" > "${lab_config}"
grep -q "^PERFLAB_PROMETHEUS_URL=\"${base}\"$" "${lab_config}" \
  || fail "PERFLAB_PROMETHEUS_URL was not redirected to the fixture backend"

package() { # package <dir> <profile> <start> <stages-json>
  mkdir -p "$1/benchmark"
  printf '{"runId":"%s","telemetryRunId":"%s","scenarioId":"E06","workload":{"profile":"%s"},"measurementStartedEpoch":%s,"measurementEndedEpoch":%s,"target":"local"}\n' \
    "$(basename "$1")" "$(basename "$1")" "$2" "$3" "$(( $3 + 60 ))" > "$1/manifest.json"
  printf '{"scenarios":{"measure":{"executor":"ramping-vus","startVUs":0,"stages":%s}}}\n' "$4" > "$1/benchmark/k6-profile.json"
}
run() { # run <dir>
  PATH="${test_root}/bin:${PATH}" PERFLAB_CONFIG="${lab_config}" \
    bash "${repo}/harness/core/analyze/analyze-stages.sh" "$1" > "$1.out" 2>&1 \
    || { cat "$1.out" >&2; fail "analyze-stages.sh failed for $(basename "$1")"; }
}

# --- case 12: spike -----------------------------------------------------------
spike="${test_root}/spike"
package "${spike}" spike "${spike_start}" \
  '[{"duration":"5s","target":10},{"duration":"15s","target":10},{"duration":"5s","target":40},{"duration":"15s","target":40},{"duration":"5s","target":10},{"duration":"15s","target":10}]'
run "${spike}"
report="${spike}/analysis/stages.json"
jq -e '.verdict == "captured" and (.stages | length) == 6' "${report}" >/dev/null || fail "spike stages were not all recorded: $(cat "${report}")"
jq -e '.stages[0].judged == false and (.stages[0].reason | test("shorter than 10 s"))' "${report}" >/dev/null \
  || fail "a 5 s ramp stage was judged from fewer than two metric exports"
jq -e '.spike.baselineStage == 1 and .spike.surgeStage == 3 and .spike.baselineP99Ms == 20 and .spike.surgeP99Ms == 300' "${report}" >/dev/null \
  || fail "spike baseline/surge holds were misidentified: $(jq -c .spike "${report}")"
jq -e '.spike.degraded == true and .stages[3].healthy == false' "${report}" >/dev/null \
  || fail "a surge with p99 300 ms and 5% errors was not reported as degraded"
jq -e '.spike.recovered == true and .spike.recoverySeconds == 15' "${report}" >/dev/null \
  || fail "recovery should be 15 s after the surge (p99 back to 22 ms at the third probe): $(jq -c .spike "${report}")"

# --- case 11: breakpoint --------------------------------------------------------
brk="${test_root}/breakpoint"
package "${brk}" breakpoint "${break_start}" \
  '[{"duration":"15s","target":32},{"duration":"15s","target":64},{"duration":"15s","target":256},{"duration":"15s","target":160}]'
run "${brk}"
report="${brk}/analysis/stages.json"
jq -e '.levels.lastHealthyTarget == 64 and .levels.firstFailingTarget == 256' "${report}" >/dev/null \
  || fail "breakpoint levels wrong: $(jq -c .levels "${report}")"
jq -e '.levels.firstFailingReasons | test("5xx ratio 0.050")' "${report}" >/dev/null \
  || fail "the first failing level does not say why: $(jq -c .levels "${report}")"
jq -e '.levels.scaledUpToTarget == 64 and .levels.plateauTarget == 256' "${report}" >/dev/null \
  || fail "throughput stopped following the load above 64 VUs (2,000 -> 2,050 rps at 4x the VUs): $(jq -c .levels "${report}")"
jq -e '.stages[3].target == 160 and .stages[3].judged == true' "${report}" >/dev/null \
  || fail "the ramp-down stage should still be reported"

# --- a constant-load profile has no stages to judge ----------------------------
steady="${test_root}/steady"
package "${steady}" steady "${spike_start}" '[]'
run "${steady}"
jq -e '.verdict == "not-applicable"' "${steady}/analysis/stages.json" >/dev/null \
  || fail "a steady run was given a stage analysis"

echo "analyze-stages tests passed"
