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
capacity_start=1800002000
transport_start=1800003000
fault_start=1800004000
delivery_start=1800005000
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
  "$((break_start + 60))": {"rps": 1900, "p99": 90,  "bad": 0},
  "$((capacity_start + 30))": {"rps": 10, "p99": 12, "bad": 0},
  "$((capacity_start + 60))": {"rps": 29, "p99": 14, "bad": 0},
  "$((transport_start + 30))": {"rps": 900, "p99": 8, "bad": 0, "sent": 30000, "failed": 0},
  "$((transport_start + 60))": {"rps": 500, "p99": 9, "bad": 0, "sent": 50000, "failed": 20000},
  "$((fault_start + 20))": {"rps": 500, "p99": 20, "bad": 0},
  "$((fault_start + 28))": {"rps": 300, "p99": 900, "bad": 30},
  "$((fault_start + 38))": {"rps": 480, "p99": 300, "bad": 0},
  "$((fault_start + 43))": {"rps": 500, "p99": 22, "bad": 0},
  "$((delivery_start + 30))": {"rps": 9.2, "p99": 10, "bad": 0},
  "$((delivery_start + 60))": {"rps": 29, "p99": 12, "bad": 0}
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
        if "k6_http_reqs_total" in promql:
            # k6 remote-write is optional: no row means it was not enabled.
            if "sent" not in row:
                body = {"status": "success", "data": {"resultType": "vector", "result": []}}
                payload = json.dumps(body).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return
            value = row["failed"] if 'status="0"' in promql else row["sent"]
        elif "histogram_quantile" in promql:
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

package() { # package <dir> <profile> <start> <stages-json> [ramping-arrival-rate]
  mkdir -p "$1/benchmark"
  printf '{"runId":"%s","telemetryRunId":"%s","scenarioId":"E06","workload":{"profile":"%s"},"measurementStartedEpoch":%s,"measurementEndedEpoch":%s,"target":"local"}\n' \
    "$(basename "$1")" "$(basename "$1")" "$2" "$3" "$(( $3 + 60 ))" > "$1/manifest.json"
  if [[ "${5:-}" == "ramping-arrival-rate" ]]; then
    printf '{"scenarios":{"measure":{"executor":"ramping-arrival-rate","startRate":1,"stages":%s}}}\n' "$4" > "$1/benchmark/k6-profile.json"
  else
    printf '{"scenarios":{"measure":{"executor":"ramping-vus","startVUs":0,"stages":%s}}}\n' "$4" > "$1/benchmark/k6-profile.json"
  fi
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

# --- an arrival ramp is judged against its linear average --------------------
# S08 and P07: a ramp from 1 to 20 req/s delivers about 10.5, not 20. Judging it
# against the end target reported a fully delivered ramp as failing.
capacity="${test_root}/capacity"
package "${capacity}" capacity "${capacity_start}" '[{"duration":"30s","target":20},{"duration":"30s","target":40}]' ramping-arrival-rate
run "${capacity}"
report="${capacity}/analysis/stages.json"
jq -e '.stages[0].expectedRate == 10.5 and .stages[0].healthy == true and .stages[1].expectedRate == 30 and .stages[1].healthy == true
       and .levels.firstFailingTarget == null' "${report}" >/dev/null \
  || fail "a fully delivered arrival ramp was not judged against its average: $(jq -c '[.stages[] | {expectedRate,servedRps,healthy,reasons}]' "${report}")"

# --- the generator decides delivery ---------------------------------------------
# S08 and P07: the served rate is a rate() over a series that only begins with
# the load, so the first ramp stage under-reads ("delivered 9.2 of 10.5") while
# k6 dropped nothing. A shortfall counts only when iterations were dropped.
delivery="${test_root}/delivery"
package "${delivery}" capacity "${delivery_start}" '[{"duration":"30s","target":20},{"duration":"30s","target":40}]' ramping-arrival-rate
run "${delivery}"
jq -e '.stages[0].healthy == true and .levels.firstFailingTarget == null' "${delivery}/analysis/stages.json" >/dev/null \
  || fail "an under-read first stage with no dropped iterations failed: $(jq -c '[.stages[] | {servedRps,healthy,reasons}]' "${delivery}/analysis/stages.json")"
printf '{"observations":[{"name":"http.dropped_iterations","value":12}]}\n' > "${delivery}/facts.json"
run "${delivery}"
jq -e '.stages[0].healthy == false and (.stages[0].reasons | test("delivered 9.2 of 10.5 req/s with 12 iterations dropped"))' "${delivery}/analysis/stages.json" >/dev/null \
  || fail "a shortfall with dropped iterations was not reported: $(jq -c '[.stages[] | {servedRps,healthy,reasons}]' "${delivery}/analysis/stages.json")"

# --- client transport errors fail a stage the server never saw ---------------
# P05: 221,657 connections were dropped before the application, so the server
# histogram showed a healthy stage while 99% of requests failed.
transport="${test_root}/transport"
package "${transport}" stress "${transport_start}" '[{"duration":"30s","target":96},{"duration":"30s","target":384}]'
run "${transport}"
report="${transport}/analysis/stages.json"
jq -e '.stages[0].healthy == true and .stages[0].transportErrorRatio == 0
       and .stages[1].healthy == false and (.stages[1].reasons | test("client transport errors 0.400"))
       and .levels.firstFailingTarget == 384' "${report}" >/dev/null \
  || fail "client transport errors did not fail the stage: $(jq -c '[.stages[] | {transportErrorRatio,healthy,reasons}]' "${report}")"
jq -e '[.stages[] | .transportErrorRatio] == [null, null, null, null]' "${brk}/analysis/stages.json" >/dev/null \
  || fail "a run without k6 remote-write invented a transport error ratio"

# --- a fault run reports its outage and recovery -------------------------------
# S22 stopped Postgres for 8 s and the package said only faultApplied/Restored.
fault="${test_root}/fault"
package "${fault}" steady "${fault_start}" '[]'
"${PYTHON}" - "${fault}/benchmark/fault-proof.json" "${fault_start}" <<'PYFAULT'
import datetime, json, sys
iso = lambda t: datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
start = int(sys.argv[2])
json.dump({"action": "stop", "service": "postgres", "applied": True, "restored": True,
           "appliedAt": iso(start + 20), "restoredAt": iso(start + 28)}, open(sys.argv[1], "w"))
PYFAULT
run "${fault}"
jq -e '.captureState == "captured" and .dependency == "postgres" and .baseline.p99Ms == 20 and .outage.p99Ms == 900
       and .outage.errorRatio == 0.1 and .degraded == true and .recovered == true and .recoverySeconds == 15' "${fault}/analysis/fault.json" >/dev/null \
  || fail "the fault outcome is wrong: $(cat "${fault}/analysis/fault.json")"
jq -e '.verdict == "not-applicable"' "${fault}/analysis/stages.json" >/dev/null || fail "a steady fault run was given a stage analysis"
[[ ! -e "${spike}/analysis/fault.json" ]] || fail "a run without a fault proof reported a fault outcome"
# A fault that was never applied has no outage to report.
jq '.applied = false' "${fault}/benchmark/fault-proof.json" > "${fault}/proof.tmp" && mv "${fault}/proof.tmp" "${fault}/benchmark/fault-proof.json"
run "${fault}"
jq -e '.captureState == "not-captured" and (.reason | test("no applied fault"))' "${fault}/analysis/fault.json" >/dev/null \
  || fail "a fault that never applied was analysed: $(cat "${fault}/analysis/fault.json")"

# --- a constant-load profile has no stages to judge ----------------------------
steady="${test_root}/steady"
package "${steady}" steady "${spike_start}" '[]'
run "${steady}"
jq -e '.verdict == "not-applicable"' "${steady}/analysis/stages.json" >/dev/null \
  || fail "a steady run was given a stage analysis"

echo "analyze-stages tests passed"
