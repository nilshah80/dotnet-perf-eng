#!/usr/bin/env bash
# An empty signal must not read as a healthy one.
#
# A Prometheus backend answering 200 with zero series still produces a file, so
# a reader sees an artifact and assumes the metric was captured. For a role
# whose absence can only mean a broken scrape or a renamed selector, that is the
# worst possible outcome: a green run carrying no saturation evidence at all.
#
# The distinction under test is three-way, not two-way:
#   failed         the query errored           -> the backend is broken
#   empty-required the query returned nothing  -> the instrumentation is broken
#   empty          the query returned nothing  -> the workload was idle, which is a fact
#
# Logs get the same treatment: whether an empty window is a gap depends on
# whether this run asked the application to log, so requiredness is explicit and
# the resolved decision travels with the evidence.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "capture-evidence-empty-signal-test: $*" >&2; exit 1; }

# shellcheck source=/dev/null
. "${repo}/harness/core/lib/python.sh"
PYTHON="$(perflab_python)" || fail "a working Python 3 interpreter was not found (tried python3, python)"

jq_bin="$(command -v jq || true)"; [[ -n "${jq_bin}" ]] || fail "jq is required"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/empty-signal-test.XXXXXX")"
server_pid=""
cleanup() {
  [[ -n "${server_pid}" ]] && { kill "${server_pid}" 2>/dev/null || true; wait "${server_pid}" 2>/dev/null || true; }
  # PERFLAB_TEST_KEEP=1 leaves the fixture behind; a failure here is usually a
  # question about what the backend actually answered.
  [[ "${PERFLAB_TEST_KEEP:-0}" == "1" ]] && { echo "fixture kept at ${test_root}" >&2; return 0; }
  rm -rf "${test_root}"
}
trap cleanup EXIT HUP INT TERM
mkdir -p "${test_root}/bin"

# jqd() shells out to dockerized jq. Swap the container for the local binary so
# the test exercises the script's parsing, not Docker.
cat > "${test_root}/bin/docker" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ "\${1:-}" == "run" ]] || exit 0
shift
while [[ \$# -gt 0 ]]; do
  case "\$1" in --rm|--interactive|-i|-t|--tty) shift ;; *) break ;; esac
done
shift   # the image reference
exec "${jq_bin}" "\$@"
EOF
chmod +x "${test_root}/bin/docker"

# A backend that is UP and answers every query successfully with no data. This
# is the case the three-way distinction exists for -- an unreachable backend
# would be caught by any implementation.
cat > "${test_root}/backend.py" <<'PY'
import http.server, json, sys, threading

EMPTY_PROM = {"status": "success", "data": {"resultType": "vector", "result": []}}
EMPTY_LOKI = {"status": "success", "data": {"resultType": "streams", "result": []}}
EMPTY_TEMPO = {"traces": []}

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/loki"):
            body = EMPTY_LOKI
        elif self.path.startswith("/api/search") or self.path.startswith("/api/traces"):
            body = EMPTY_TEMPO
        else:
            body = EMPTY_PROM
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

# Started as a plain background job rather than through a process substitution:
# `$!` is then the pid cleanup needs, so recovering it with pgrep is unnecessary.
# pgrep is procps and Git Bash does not ship it, so the pgrep form aborted the
# whole test on Windows before a single assertion ran.
"${PYTHON}" "${test_root}/backend.py" > "${test_root}/port" 2> "${test_root}/backend.err" &
server_pid=$!
for _ in $(seq 1 100); do
  [[ -s "${test_root}/port" ]] && break
  kill -0 "${server_pid}" 2>/dev/null || break
  sleep 0.1
done
# Python's stdout is a text stream, so on Windows the port arrives as "NNNN\r\n"
# and the CR would end up inside the base URL.
if [[ ! -s "${test_root}/port" ]]; then
  cat "${test_root}/backend.err" >&2
  fail "fake backend exited or timed out before reporting a port"
fi
read -r port < "${test_root}/port"
port="${port%$'\r'}"
[[ -n "${port}" ]] || fail "fake backend did not report a port"
base="http://127.0.0.1:${port}"
curl -fsS --max-time 5 "${base}/api/v1/query?query=up" >/dev/null || fail "fake backend is not answering"

now="$(date +%s)"
write_package() { # write_package <dir>
  mkdir -p "$1/benchmark"
  # A measured package always carries the generator's observations and its
  # compatibility envelope; facts.json is built from them, and the derived
  # efficiency queries (whose provenance case 8 checks) run only after that.
  printf '{"observations":[{"name":"http.requests_per_second","value":100,"unit":"rps"}]}\n' > "$1/benchmark/observations.json"
  printf '{"generator":"k6","generatorFingerprint":"k6-fixture","workloadContentHash":"%s","configurationHash":"%s"}\n' \
    "$(printf 'a%.0s' $(seq 1 64))" "$(printf 'b%.0s' $(seq 1 64))" > "$1/benchmark/compatibility.json"
  cat > "$1/manifest.json" <<JSON
{"runId":"run-empty","telemetryRunId":"run-empty","scenarioId":"S01",
 "workload":{"loadGenerator":"k6"},"startedEpoch":$((now - 120)),
 "measurementStartedEpoch":$((now - 60)),"measurementEndedEpoch":${now},
 "target":"local","remoteTelemetry":false,"continuousProfiling":false}
JSON
}

# The lab descriptor ASSIGNS the backend URLs rather than defaulting them, so an
# environment override would be discarded. Derive the fixture lab from the real
# descriptor and rewrite only the three endpoints: the test then tracks the lab
# it is testing instead of drifting from a hand-copied duplicate.
lab_config="${test_root}/lab.config.sh"
sed -e "s|^PERFLAB_PROMETHEUS_URL=.*|PERFLAB_PROMETHEUS_URL=\"${base}\"|" \
    -e "s|^PERFLAB_TEMPO_URL=.*|PERFLAB_TEMPO_URL=\"${base}\"|" \
    -e "s|^PERFLAB_LOKI_URL=.*|PERFLAB_LOKI_URL=\"${base}\"|" \
    "${repo}/labs/scenariolab/lab.config.sh" > "${lab_config}"
for var in PERFLAB_PROMETHEUS_URL PERFLAB_TEMPO_URL PERFLAB_LOKI_URL; do
  grep -q "^${var}=\"${base}\"$" "${lab_config}" \
    || fail "${var} was not redirected to the fixture backend; the descriptor's shape changed"
done

run_capture() { # run_capture <dir> <request-logging>
  PATH="${test_root}/bin:${PATH}" \
  PERFLAB_CONFIG="${lab_config}" \
  PERFLAB_REQUEST_LOGGING="$2" \
    bash "${repo}/harness/core/capture/capture-evidence.sh" "$1" > "$1.out" 2>&1 || true
}

role_state() { # role_state <package> <role>
  jq -r --arg a "telemetry/metrics/$2.json" \
    'select(.artifact == $a) | .captureState' < "$1/telemetry/queries.ndjson" | head -1
}

# The required-role list belongs to the runtime adapter, not the environment: a
# .NET process under load always has a thread pool, and never having touched the
# database is a property of the scenario. So the contrast lives inside ONE run --
# same backend, same empty answer, two roles, two gradings.
pkg="${test_root}/grading"
write_package "${pkg}"
run_capture "${pkg}" Warning

# 1. A required role with no series means the scrape, selector or instrumentation
#    broke. That must degrade the package.
state="$(role_state "${pkg}" thread_pool_queue)"
[[ "${state}" == "empty-required" ]] \
  || fail "a required role with no series graded '${state}', not empty-required"
grep -q "required metric role 'thread_pool_queue' returned no series" "${pkg}.out" \
  || fail "no warning named the broken role"
grep -q 'this is not an idle process' "${pkg}.out" \
  || fail "the warning must rule out the benign reading, or a reader will assume it"

# 2. The SAME empty answer for a conditional role is a fact about the workload:
#    a scenario that never opens a connection has no pool metrics, and calling
#    that missing evidence would mark a correct package incomplete. If both
#    graded alike the required list would be decoration.
state="$(role_state "${pkg}" database_pool_metrics)"
[[ "${state}" == "empty" ]] \
  || fail "a conditional role with no series graded '${state}', not empty"
grep -q "required metric role 'database_pool_metrics'" "${pkg}.out" \
  && fail "a conditional role was reported as a broken required role"

# 3. A backend that is DOWN is a third state again -- the evidence is missing
#    because nothing answered, which is a different repair than a bad selector.
[[ "$(role_state "${pkg}" thread_pool_queue)" != "failed" ]] \
  || fail "a reachable backend was graded as a failed query"

# 4. Log requiredness is explicit, and the resolved decision is recorded next to
#    the logs so a reader never has to reconstruct which case an empty window is.
policy="${pkg}/telemetry/logs/policy.json"
[[ -s "${policy}" ]] || fail "no telemetry/logs/policy.json was written"
jq -e '.requestLoggingLevel == "Warning" and .logsRequired == false
       and .captureState == "empty"' "${policy}" >/dev/null \
  || fail "policy.json does not record the decision it made: $(cat "${policy}")"
grep -q 'a healthy path emits none' "${pkg}.out" \
  || fail "an empty non-required log window must be explained, not silent"

# 5. With request logging ON, the same empty window IS a gap.
logging_pkg="${test_root}/logging-on"
write_package "${logging_pkg}"
run_capture "${logging_pkg}" Information
policy="${logging_pkg}/telemetry/logs/policy.json"
jq -e '.requestLoggingLevel == "Information" and .logsRequired == true
       and .captureState == "missing"' "${policy}" >/dev/null \
  || fail "logging-on empty window was not treated as missing: $(cat "${policy}")"
grep -q 'the logs are MISSING' "${logging_pkg}.out" \
  || fail "a required-but-empty log window produced no warning"

# 6. The override is honoured in the other direction too: a run may declare logs
#    required at a level whose default would not.
override_pkg="${test_root}/override"
write_package "${override_pkg}"
PERFLAB_LOGS_REQUIRED=1 run_capture "${override_pkg}" Warning
jq -e '.logsRequired == true and .captureState == "missing"' \
  "${override_pkg}/telemetry/logs/policy.json" >/dev/null \
  || fail "PERFLAB_LOGS_REQUIRED=1 did not override the level-derived default"

# 7. Telemetry-loss accounting must run on the LOCAL path too (D-P0-9). Every
#    other signal here is read through the collector, so a silent drop makes an
#    incomplete capture look complete -- one layer below where the capture states
#    can see it. This lived in the remote-only branch, which meant it never ran
#    for any lab run in either repository.
for role in telemetry_export_failures telemetry_queue_utilization telemetry_refused; do
  [[ -s "${pkg}/telemetry/metrics/${role}.json" ]] \
    || fail "${role} was not captured on the local path"
  jq -e --arg a "telemetry/metrics/${role}.json" \
     'select(.artifact == $a) | .endpoint == "/api/v1/query_range"' \
     < "${pkg}/telemetry/queries.ndjson" >/dev/null \
    || fail "${role} must be a window query; an instant one cannot see a drop inside the window"
done

# 8. Query provenance (D-P2-7) must carry every parameter a replay needs. A
#    range record without its step, an instant record without its evaluation
#    time, or a slice without its retry history describes a request that was
#    never made -- and the derived efficiency scalars had no record at all.
queries="${pkg}/telemetry/queries.ndjson"
jq -e 'select(.endpoint == "/api/v1/query_range" and .backend == "prometheus")
       | select((.step // 0) != 5 or (.attempts // 0) < 1 or (.lastExit // 1) != 0)' \
   < "${queries}" | grep -q . \
  && fail "a Prometheus range record lacks step, attempts or lastExit"
jq -e 'select(.artifact == "telemetry/metrics/cpu_count.json")
       | select(.endpoint == "/api/v1/query" and .time == '"${now}"')' \
   < "${queries}" | grep -q . \
  || fail "the instant cpu_count record does not pin time= to the window end"
jq -e 'select(.derived == true and (.artifact | startswith("facts.json#observations/efficiency.")))
       | select(.endpoint == "/api/v1/query" and .time == '"${now}"' and .captureState == "empty")' \
   < "${queries}" | grep -q . \
  || fail "derived efficiency queries were not recorded with their pinned time and empty state"
jq -e 'select(.backend == "tempo" and .endpoint == "/api/search" and (.page // 0) >= 1)
       | select(.attempts == 1 and .lastExit == 0 and .captureState == "captured")' \
   < "${queries}" | grep -q . \
  || fail "Tempo slice records do not carry page, attempts and lastExit"
jq -e 'select(.backend == "loki" and .page == 1)
       | select(.direction == "backward" and .attempts == 1 and .lastExit == 0
                and (.startNanos | type) == "string" and (.endNanos | type) == "string")' \
   < "${queries}" | grep -q . \
  || fail "Loki page records do not carry cursor bounds and retry history"

# 9. Phase scoping (D-P1-8) follows the pre-traffic baggage proof and nothing
#    else. Without a verified proof no query names perf_phase; with one, the
#    request-duration metric, the Tempo search and the Loki query select the
#    measured phase -- and the runtime metrics, which never carry that label,
#    stay unscoped rather than going empty.
jq -e 'select(.query | tostring | test("perf_phase|perf\\.phase"))' < "${queries}" | grep -q . \
  && fail "a run without a baggage proof selected a phase"
scoped="${test_root}/phase-scoped"
write_package "${scoped}"
mkdir -p "${scoped}/analysis"
printf '{"schemaVersion":"baggage-contract-v1","version":"perflab-baggage-v1","state":"verified","phaseScoped":true}\n' \
  > "${scoped}/analysis/baggage-contract.json"
run_capture "${scoped}" Warning
scoped_queries="${scoped}/telemetry/queries.ndjson"
jq -e 'select(.artifact == "telemetry/metrics/request_duration.json") | .query | contains("perf_phase=\"measure\"")' \
   < "${scoped_queries}" | grep -q true || fail "the request-duration query did not select the measured phase"
jq -e 'select(.backend == "tempo") | .query | contains("span.perf.phase = \"measure\"")' \
   < "${scoped_queries}" | grep -q true || fail "the Tempo search did not select the measured phase"
jq -e 'select(.backend == "loki") | .query | contains("| perf_phase=\"measure\"")' \
   < "${scoped_queries}" | grep -q true || fail "the Loki query did not select the measured phase"
jq -e 'select(.artifact == "telemetry/metrics/process_cpu.json") | .query | contains("perf_phase")' \
   < "${scoped_queries}" | grep -q true && fail "a runtime metric was phase-scoped; it carries no phase label"

echo "capture-evidence empty-signal tests passed"
