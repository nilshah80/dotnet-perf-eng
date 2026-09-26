#!/usr/bin/env bash
# The bottleneck classifier saturation rules.
#
# Both of these produced a confidently wrong verdict before they were fixed, in
# the same way: a number crossed a threshold and the classifier named it the
# bottleneck without asking what the number meant.
#
#   QUEUE DEPTH is not queue WAIT. A depth of 20 at 2000 rps drains in 10 ms and
#   is just burst arrival; the same depth at 50 rps is 400 ms of real waiting.
#   Judging on depth alone diagnosed S04 -- an allocation problem -- as thread
#   pool starvation, and an engineer following that verdict would have gone
#   looking for blocking calls that were not there.
#
#   RETENTION is not a latency bottleneck. A growing heap must be reported, but
#   it must never outrank a resource that is actually saturated, or every leaky
#   run would be diagnosed as a leak regardless of what was slow.
#
#   AN UNMODELLED RESOURCE gets blamed on whatever IS modelled. With no upstream
#   connection-pool dimension, S25 -- 64 requests queued behind 2 connections,
#   2.8 s of every 3.3 s request spent waiting for one -- was reported as
#   thread-pool starvation, because the queue was the only queue the classifier
#   knew about.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "bottleneck-rules-test: $*" >&2; exit 1; }

# shellcheck source=/dev/null
. "${repo}/harness/core/lib/python.sh"
PYTHON="$(perflab_python)" || fail "a working Python 3 interpreter was not found (tried python3, python)"

jq_bin="$(command -v jq || true)"; [[ -n "${jq_bin}" ]] || fail "jq is required"
docker_bin="$(command -v docker || true)"; [[ -n "${docker_bin}" ]] || fail "docker is required"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/bottleneck-rules-test.XXXXXX")"
trap '[[ "${PERFLAB_TEST_KEEP:-0}" == "1" ]] && echo "fixture kept at ${test_root}" >&2 || rm -rf "${test_root}"' EXIT HUP INT TERM
mkdir -p "${test_root}/bin"

cat > "${test_root}/bin/docker" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" != "run" ]]; then exec "${docker_bin}" "\$@"; fi
shift
while [[ \$# -gt 0 ]]; do
  case "\$1" in --rm|--interactive|-i|-t|--tty) shift ;; *) break ;; esac
done
shift
exec "${jq_bin}" "\$@"
EOF
chmod +x "${test_root}/bin/docker"

# build_run <name> <rps> <cores-busy> <queue-depth> <heap-growth-pct|"">
# Eight cores throughout, so cores-busy reads directly as a utilisation.
build_run() {
  local name="$1" rps="$2" cores="$3" queue="$4" growth="$5" upwait="${6:-0.002}" upactive="${7:-1}" upconns="${8:-4}"
  local dir="${test_root}/${name}"
  mkdir -p "${dir}/telemetry/metrics" "${dir}/analysis/runtime"
  "${PYTHON}" - "${dir}" "${rps}" "${cores}" "${queue}" "${growth}" "${upwait}" "${upactive}" "${upconns}" <<'PY'
import json, os, sys
dir_, rps, cores, queue, growth, upwait, upactive, upconns = sys.argv[1:9]

def series(path, value, metric=None):
    # Prometheus range shape: a flat series is enough -- the classifier reduces
    # with max/avg, so a constant value makes the expected reduction obvious.
    body = {"status": "success", "data": {"resultType": "matrix", "result": [
        {"metric": metric or {}, "values": [[1700000000 + i * 5, str(value)] for i in range(12)]}
    ]}}
    with open(os.path.join(dir_, "telemetry/metrics", path + ".json"), "w") as f:
        json.dump(body, f)

series("process_cpu", cores)
series("cpu_count", 8)
series("thread_pool_queue", queue)
series("thread_count", 32)
series("gc_pause", 0.01)          # 1% of wall clock: below the 10% gate
series("gc_allocation_rate", 4.0e8)
series("lock_contention", 0.0)

# The upstream pool carries TWO pools on purpose: the app's own OTLP exporter is
# an HttpClient too, and ranking must pick the dependency the workload calls
# rather than the exporter's idle connections.
wait_count = 1000.0
http = {"status": "success", "data": {"resultType": "matrix", "result": [
    {"metric": {"__name__": "http_client_request_time_in_queue_seconds_sum", "server_address": "upstream"},
     "values": [[1700000000, str(float(upwait) * wait_count)]]},
    {"metric": {"__name__": "http_client_request_time_in_queue_seconds_count", "server_address": "upstream"},
     "values": [[1700000000, str(wait_count)]]},
    {"metric": {"__name__": "http_client_active_requests", "server_address": "upstream"},
     "values": [[1700000000, upactive]]},
    {"metric": {"__name__": "http_client_open_connections", "server_address": "upstream",
                "http_connection_state": "active"}, "values": [[1700000000, upconns]]},
    # The exporter: busy by count, trivial by wait.
    {"metric": {"__name__": "http_client_request_time_in_queue_seconds_sum", "server_address": "lgtm"},
     "values": [[1700000000, "0.9"]]},
    {"metric": {"__name__": "http_client_request_time_in_queue_seconds_count", "server_address": "lgtm"},
     "values": [[1700000000, "900"]]},
    {"metric": {"__name__": "http_client_open_connections", "server_address": "lgtm",
                "http_connection_state": "idle"}, "values": [[1700000000, "8"]]},
]}}
with open(os.path.join(dir_, "telemetry/metrics", "http_client_metrics.json"), "w") as f:
    json.dump(http, f)

facts = {
    "runId": "run-" + os.path.basename(dir_), "telemetryRunId": "run-" + os.path.basename(dir_),
    "scenarioId": "SXX", "status": "captured",
    "observations": [
        {"name": "http.requests_per_second", "value": float(rps)},
        {"name": "http.latency.p50", "value": 12.0},
        {"name": "http.latency.p99", "value": 240.0},
        {"name": "http.error_rate", "value": 0.0},
        {"name": "efficiency.cpu_ms_per_request", "value": 3.0},
        {"name": "efficiency.gc_pause_ms_per_request", "value": 0.4},
        {"name": "efficiency.db_ms_per_request", "value": 0.2},
        {"name": "efficiency.alloc_bytes_per_request", "value": 900000.0},
    ],
}
with open(os.path.join(dir_, "facts.json"), "w") as f:
    json.dump(facts, f)

if growth:
    with open(os.path.join(dir_, "analysis/runtime/diff-gcdump-before-after.txt"), "w") as f:
        f.write("gcdump before/after diff\n")
        f.write("total delta: +412837120 bytes (+%s%%)\n" % growth)
PY
  PATH="${test_root}/bin:${PATH}" PERFLAB_LAB=scenariolab \
    bash "${repo}/harness/core/analyze/bottleneck.sh" "${dir}" > "${dir}/run.out" 2>&1 \
    || fail "${name}: bottleneck.sh failed:\n$(cat "${dir}/run.out")"
  printf '%s' "${dir}/analysis/bottleneck.json"
}

verdict()  { jq -r '.verdict' < "$1"; }
classify() { # re-classify a fixture directory after editing its evidence
  PATH="${test_root}/bin:${PATH}" PERFLAB_LAB=scenariolab \
    bash "${repo}/harness/core/analyze/bottleneck.sh" "$1" > "$1/run.out" 2>&1 \
    || fail "$(basename "$1"): bottleneck.sh failed: $(cat "$1/run.out")"
}
notes()    { jq -r '(.notes // [])[]' < "$1"; }

# 1. The S04 shape: a queue that is DEEP but drains fast. Depth 20 at 2000 rps is
#    10 ms of waiting -- burst arrival, not starvation.
transient="$(build_run transient 2000 1.0 20 "")"
[[ "$(verdict "${transient}")" != "threadpool-starved" ]] \
  || fail "a queue draining in 10 ms was diagnosed as thread pool starvation"
jq -e '.resources.threadPool.saturated == false' "${transient}" >/dev/null \
  || fail "a fast-draining queue was marked saturated"
jq -e '.resources.threadPool.queueWaitSeconds < 0.05' "${transient}" >/dev/null \
  || fail "queueWaitSeconds was not computed from depth and throughput"
notes "${transient}" | grep -q 'transient depth, not starvation' \
  || fail "the depth was not explained away, so a reader still sees an alarming 20"

# 2. The SAME depth at low throughput IS starvation: 20 items at 50 rps is 400 ms
#    of waiting. If this did not fire, rule 1 would just be a blanket suppression.
starved="$(build_run starved 50 1.0 20 "")"
[[ "$(verdict "${starved}")" == "threadpool-starved" ]] \
  || fail "a queue with 400 ms of backlog was not diagnosed as starvation (got $(verdict "${starved}"))"
jq -e '.resources.threadPool.queueWaitSeconds >= 0.05' "${starved}" >/dev/null \
  || fail "backlog seconds were not computed for the starved case"

# 3. The same queue depth WITH saturated CPU is a symptom, not the disease: the
#    threads are busy, not parked, so cpu-bound must win and say so.
cpu_bound="$(build_run cpu-bound 50 7.6 20 "")"
[[ "$(verdict "${cpu_bound}")" == "cpu-bound" ]] \
  || fail "a queue behind saturated CPU outranked the CPU (got $(verdict "${cpu_bound}"))"
notes "${cpu_bound}" | grep -q 'CPU starvation, not sync-over-async' \
  || fail "the queue-behind-CPU case was not explained"

# 4. A heap that grew by an order of magnitude while nothing saturated must be
#    REPORTED but must not become the verdict -- retention is not latency.
retained="$(build_run retained 2000 1.0 0 1324.2)"
[[ "$(verdict "${retained}")" != *"retain"* && "$(verdict "${retained}")" != *"leak"* ]] \
  || fail "retention became the primary verdict (got $(verdict "${retained}"))"
jq -e '.resources.retention.flagged == true' "${retained}" >/dev/null \
  || fail "a 1324% heap growth was not flagged"
jq -e '.resources.retention.source == "analysis/runtime/diff-gcdump-before-after.txt"' "${retained}" >/dev/null \
  || fail "the retention finding does not cite the artifact it came from"
notes "${retained}" | grep -q 'RETENTION, not a latency bottleneck' \
  || fail "retention was flagged without saying what it does and does not mean"

# 5. Retention must not outrank a resource that IS saturated, or a leaky run
#    would always be diagnosed as a leak whatever was actually slow.
both="$(build_run retained-and-starved 50 1.0 20 1324.2)"
[[ "$(verdict "${both}")" == "threadpool-starved" ]] \
  || fail "retention displaced a genuinely saturated resource (got $(verdict "${both}"))"
jq -e '.resources.retention.flagged == true' "${both}" >/dev/null \
  || fail "retention stopped being reported once something else saturated"

# 6. Absent gcdump is 'not captured', which must not read as 'no growth'.
jq -e '.resources.retention.flagged == false and .resources.retention.source == "not-captured"
       and .resources.retention.heapGrowthPct == null' "${transient}" >/dev/null \
  || fail "a run with no gcdump pair reported retention as measured-and-fine"

# 7. A dimension that was not captured must degrade only itself. Reading the
#    absent DB-pool file used to abort the classifier under `set -e` -- exit 1,
#    no message, no verdict for ANY resource -- so a lab with no database, or one
#    whose pool query failed, lost the entire diagnosis to a missing side signal.
jq -e '.resources.dbPool.usedPeak == null and .resources.dbPool.max == null
       and .resources.dbPool.saturated == false' "${transient}" >/dev/null \
  || fail "an uncaptured DB pool was reported as measured"
[[ -n "$(verdict "${transient}")" && "$(verdict "${transient}")" != "null" ]] \
  || fail "a missing DB-pool signal cost the run its verdict entirely"

# 8. The upstream connection pool is its own dimension. 64 requests against 2
#    connections, waiting 2.8 s each, is the pool -- not the thread-pool queue
#    that the waiting produces.
upstream="$(build_run upstream 20 0.3 2 "" 2.8 64 2)"
[[ "$(verdict "${upstream}")" == "upstream-pool-saturated" ]] \
  || fail "a 2.8 s wait for an upstream connection was diagnosed as $(verdict "${upstream}")"
jq -e '.resources.upstreamPool.saturated == true
       and .resources.upstreamPool.meanWaitSeconds >= 2.5
       and .resources.upstreamPool.pool == "upstream"' "${upstream}" >/dev/null \
  || fail "the upstream pool was not measured, or the wrong pool was ranked: $(jq -c .resources.upstreamPool "${upstream}")"
notes "${upstream}" | grep -q 'MaxConnectionsPerServer' \
  || fail "the finding does not say what to change"

# 9. The thread-pool queue must be reported as a SYMPTOM here, not as a second
#    independent diagnosis. Two contradictory notes -- look for blocking calls,
#    and raise the pool limit -- is worse than one correct one.
notes "${upstream}" | grep -q 'symptom of connection waiting' \
  || fail "the queue behind the upstream pool was not explained"
notes "${upstream}" | grep -q 'sync-over-async' \
  && fail "the classifier blamed sync-over-async while the upstream pool explained the queue"

# 10. The app exporter is an HttpClient too. A normal run must not be diagnosed
#     on the OTLP client, and normal pooling (a few ms) must not saturate.
healthy="$(build_run upstream-healthy 2000 0.3 0 "" 0.002 4 8)"
jq -e '.resources.upstreamPool.saturated == false
       and .resources.upstreamPool.pool == "upstream"' "${healthy}" >/dev/null \
  || fail "millisecond connection acquisition was treated as saturation: $(jq -c .resources.upstreamPool "${healthy}")"
[[ "$(verdict "${healthy}")" != "upstream-pool-saturated" ]] \
  || fail "a healthy upstream pool became the verdict"

# 11. A lab with no upstream client at all keeps its verdict: the dimension
#     degrades to not-captured rather than to zero-and-fine.
rm -f "$(dirname "$(dirname "${transient}")")/telemetry/metrics/http_client_metrics.json"
PATH="${test_root}/bin:${PATH}" PERFLAB_LAB=scenariolab \
  bash "${repo}/harness/core/analyze/bottleneck.sh" "${test_root}/transient" >/dev/null 2>&1 \
  || fail "a run with no upstream client crashed the classifier"
jq -e '.resources.upstreamPool.saturated == false and .resources.upstreamPool.meanWaitSeconds == null' \
  "${transient}" >/dev/null \
  || fail "an uncaptured upstream pool reported as measured-and-fine"

# 12. Acceptance case 10: target saturation must be distinguishable from
#     GENERATOR starvation. Dropped iterations mean the load generator never
#     delivered the offered rate, so every server-side number describes a
#     workload that did not happen. Reporting a server bottleneck from it would
#     send an engineer to tune a system that was never asked to do the work.
starved_gen="$(build_run generator-starved 50 0.3 0 "")"
starved_dir="$(dirname "$(dirname "${starved_gen}")")"
jq '.observations += [{"name":"http.dropped_iterations","value":4120}]' \
  "${starved_dir}/facts.json" > "${starved_dir}/facts.json.tmp"
mv "${starved_dir}/facts.json.tmp" "${starved_dir}/facts.json"
PATH="${test_root}/bin:${PATH}" PERFLAB_LAB=scenariolab \
  bash "${repo}/harness/core/analyze/bottleneck.sh" "${starved_dir}" >/dev/null 2>&1 \
  || fail "the classifier failed on a run with dropped iterations"
notes "${starved_gen}" | grep -q 'dropped iteration' \
  || fail "dropped iterations were not surfaced, so generator starvation reads as server behaviour"
notes "${starved_gen}" | grep -q 'scheduled load was not delivered' \
  || fail "the note does not say the offered load was never delivered"

# Aggregate CPU work can exceed wall latency without CPU saturation (P01).
ratio_run="$(build_run cpu-cost-not-saturation 30 0.15 0 "")"
ratio_dir="$(dirname "$(dirname "${ratio_run}")")"
jq '(.observations[] | select(.name == "http.latency.p50").value) = 1
    | (.observations[] | select(.name == "efficiency.cpu_ms_per_request").value) = 4.2'   "${ratio_dir}/facts.json" > "${ratio_dir}/facts.json.tmp"
mv "${ratio_dir}/facts.json.tmp" "${ratio_dir}/facts.json"
PATH="${test_root}/bin:${PATH}" PERFLAB_LAB=scenariolab   bash "${repo}/harness/core/analyze/bottleneck.sh" "${ratio_dir}" >/dev/null 2>&1
[[ "$(verdict "${ratio_run}")" != cpu-bound ]] || fail "CPU cost/latency ratio was mistaken for saturation"
notes "${ratio_run}" | grep -q 'system has headroom' && fail "absence of saturation was advertised as headroom"
notes "${starved_gen}" | grep -q 'past the knee' && fail "generator drops were attributed to server capacity"

# Captured fractional quotas apply per instance; two half-core replicas each
# using 0.45 cores are 90% utilized, not 180% or 45%.
quota_run="$(build_run fractional-quota 30 0.45 0 "")"
quota_dir="$(dirname "$(dirname "${quota_run}")")"
mkdir -p "${quota_dir}/environment/measurement-start"
"${PYTHON}" - "${quota_dir}" <<'PYFIX'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);m=p/'telemetry/metrics'
for name in ['process_cpu','cpu_count']:
 d=json.loads((m/(name+'.json')).read_text());rows=[]
 for instance in ['a','b']:
  row=dict(d['data']['result'][0]);row['metric']={'service_instance_id':instance,'service_name':'service-'+instance}
  if name=='cpu_count': row['values']=[[1790340000,'1']]
  rows.append(row)
 d['data']['result']=rows;(m/(name+'.json')).write_text(json.dumps(d))
(p/'environment/measurement-start/resource-limits.json').write_text(json.dumps([
 {'telemetryService':'service-a','cpuLimit':0.5,'telemetryExporterAuthority':'lgtm:4317'},
 {'telemetryService':'service-b','cpuLimit':0.5,'telemetryExporterAuthority':'lgtm:4317'}]))
# An exporter with a huge old cumulative wait must never explain request latency.
f=m/'http_client_metrics.json';d=json.loads(f.read_text())
for row in d['data']['result']:
 row['metric']['server_port']='4317' if row['metric']['server_address']=='lgtm' else '80'
 if row['metric']['server_address']=='lgtm' and row['metric']['__name__'].endswith('_sum'): row['values']=[[1700000000,'90000']]
f.write_text(json.dumps(d))
PYFIX
PATH="${test_root}/bin:${PATH}" PERFLAB_LAB=scenariolab   bash "${repo}/harness/core/analyze/bottleneck.sh" "${quota_dir}" >/dev/null 2>&1
jq -e '.resources.cpu.utilizationPct == 90 and .resources.cpu.cpuCount == 0.5
  and .resources.upstreamPool.pool == "upstream" and .resources.upstreamPool.saturated == false' "${quota_run}" >/dev/null   || fail "replica quota or exporter attribution is wrong"

# One high queue point during a spike must not become sustained starvation.
spike="$(build_run isolated-queue 148 0.2 24 "")"
"${PYTHON}" - "$(dirname "$(dirname "${spike}")")/telemetry/metrics/thread_pool_queue.json" <<'PYSPIKE'
import json,sys
p=sys.argv[1];d=json.load(open(p))
for row in d['data']['result']:
 for i,point in enumerate(row['values']): point[1]='24' if i==5 else '0'
open(p,'w').write(json.dumps(d))
PYSPIKE
PATH="${test_root}/bin:${PATH}" PERFLAB_LAB=scenariolab bash "${repo}/harness/core/analyze/bottleneck.sh" "$(dirname "$(dirname "${spike}")")" >/dev/null
jq -e '.resources.threadPool.saturated == false and .verdict != "threadpool-starved" and any(.notes[];contains("isolated"))' "${spike}" >/dev/null \
  || fail "one isolated queue point was promoted to sustained starvation"


# --- DB time above the median names both values with a decimal --------------
# The checkout journey's 2.16 ms of DB time against a 1.84 ms median used to
# read "mean database time per request (2 ms) exceeds the median request
# latency (2 ms)".
report="$(build_run dbshare 100 0.05 0 "")"
dbdir="$(dirname "$(dirname "${report}")")"
jq '(.observations[] | select(.name == "http.latency.p50") | .value) = 1.84
    | (.observations[] | select(.name == "efficiency.db_ms_per_request") | .value) = 2.16' \
  "${dbdir}/facts.json" > "${dbdir}/facts.json.tmp" && mv "${dbdir}/facts.json.tmp" "${dbdir}/facts.json"
PATH="${test_root}/bin:${PATH}" PERFLAB_LAB=scenariolab bash "${repo}/harness/core/analyze/bottleneck.sh" "${dbdir}" > "${dbdir}/run.out" 2>&1 \
  || fail "dbshare: bottleneck.sh failed"
jq -e '.verdict == "dependency-bound-db" and (.reason | test("\\(2\\.2 ms\\) exceeds the median request latency \\(1\\.8 ms\\)"))' "${report}" >/dev/null \
  || fail "DB-share wording lost its decimals: $(jq -r .reason "${report}")"

# --- Generator-host port exhaustion is the generator's limit ----------------
# P02 churned a new WebSocket per iteration: host TIME_WAIT toward the target
# reached 10,190 of 16,384 ephemeral ports and new connections failed on the
# generator. Blaming the target (or calling it overload) would be wrong.
for peak in 10190 3000; do
  report="$(build_run "generator-ports-${peak}" 800 0.3 0 "")"
  dir="$(dirname "$(dirname "${report}")")"
  mkdir -p "${dir}/dependencies"
  printf '{"schemaVersion":"generator-ports-v1","host":"127.0.0.1","ephemeralRange":16384,"threshold":4096,"timeWaitBefore":300,"timeWaitAtStart":300,"waitedSeconds":0,"state":"clear"}\n' > "${dir}/analysis/generator-ports.json"
  printf '{"atEpoch":1,"sequence":1,"captureState":"captured","generatorTimeWait":300}\n{"atEpoch":2,"sequence":2,"captureState":"captured","generatorTimeWait":%s}\n' "${peak}" > "${dir}/dependencies/api-sockets-series.ndjson"
  classify "${dir}"
  if [[ "${peak}" == 10190 ]]; then
    jq -e '.verdict == "generator-limited" and .confidence == "high" and .resources.generatorPorts.exhausted == true
           and (.reason | test("10190 sockets in TIME_WAIT toward 127.0.0.1"))' "${report}" >/dev/null \
      || fail "generator port exhaustion was not reported as the generator's limit: $(jq -c '{verdict,reason}' "${report}")"
  else
    jq -e '.verdict != "generator-limited" and .resources.generatorPorts.exhausted == false' "${report}" >/dev/null \
      || fail "normal generator port use was reported as exhaustion"
  fi
done

# --- Response classes: client errors are not overload; shedding is by design --
# E03 over JMeter got HTTP 401 on every request (no token) and was explained as
# an overloaded system; P04's explicit 429 backpressure read the same way.
responses() { # responses <dir> <code:count>...  -> request_duration.json with cumulative counts
  local dir="$1"; shift
  "${PYTHON}" - "${dir}" "$@" <<'PYRESP'
import json, sys
rows = []
for spec in sys.argv[2:]:
    code, count = spec.split(":")
    rows.append({"metric": {"__name__": "http_server_request_duration_seconds_count", "http_route": "/api/x",
                            "http_response_status_code": code},
                 "values": [[1700000000, "0"], [1700000060, count]]})
json.dump({"status": "success", "data": {"resultType": "matrix", "result": rows}},
          open(sys.argv[1] + "/telemetry/metrics/request_duration.json", "w"))
PYRESP
}
report="$(build_run client-errors 20 0.1 0 "")"; dir="$(dirname "$(dirname "${report}")")"
responses "${dir}" 401:1237
jq '(.observations[] | select(.name == "http.error_rate") | .value) = 1' "${dir}/facts.json" > "${dir}/facts.json.tmp" && mv "${dir}/facts.json.tmp" "${dir}/facts.json"
classify "${dir}"
jq -e '.verdict == "client-errors" and .confidence == "high" and (.reason | test("HTTP 401 on 100% of 1237 requests"))
       and all(.notes[]; contains("OVERLOADED") | not)' "${report}" >/dev/null \
  || fail "a run of HTTP 401s was not reported as an invalid workload: $(jq -c '{verdict,reason,notes}' "${report}")"
# A status series that first appears inside the window counts from zero.
report="$(build_run late-401 20 0.1 0 "")"; dir="$(dirname "$(dirname "${report}")")"
responses "${dir}" 200:100
jq '.data.result += [{"metric":{"__name__":"http_server_request_duration_seconds_count","http_route":"/api/x","http_response_status_code":"401"},"values":[[1700000030,"5000"]]}]' \
  "${dir}/telemetry/metrics/request_duration.json" > "${dir}/rd.json" && mv "${dir}/rd.json" "${dir}/telemetry/metrics/request_duration.json"
classify "${dir}"
jq -e '.resources.responses.clientErrors == 5000 and .verdict == "client-errors"' "${report}" >/dev/null \
  || fail "a status series that appeared mid-window was not counted: $(jq -c '.resources.responses' "${report}")"
report="$(build_run shedding 13000 7.6 0 "")"; dir="$(dirname "$(dirname "${report}")")"
responses "${dir}" 202:4000 429:776000
jq '(.observations[] | select(.name == "http.error_rate") | .value) = 0.995' "${dir}/facts.json" > "${dir}/facts.json.tmp" && mv "${dir}/facts.json.tmp" "${dir}/facts.json"
classify "${dir}"
jq -e '.verdict == "cpu-bound" and any(.notes[]; test("shed load explicitly")) and all(.notes[]; contains("OVERLOADED") | not)' "${report}" >/dev/null \
  || fail "explicit 429 backpressure was not reported as load shedding: $(jq -c '{verdict,notes}' "${report}")"

# --- Database server, pool cause, waiting, allocation, cache, exceptions -----
observe() { # observe <dir> <name> <value>: set (or add) one facts observation
  jq --arg n "$2" --argjson v "$3" 'if any(.observations[]; .name == $n) then (.observations[] | select(.name == $n) | .value) = $v
    else .observations += [{name: $n, value: $v}] end' "$1/facts.json" > "$1/facts.json.tmp" && mv "$1/facts.json.tmp" "$1/facts.json"
}
pool() { # pool <dir> <used> <max> <pending> <timeouts-first> <timeouts-last> <created> <executing> [idle] [created-first]
  "${PYTHON}" - "$@" <<'PYPOOL'
import json, sys
d, used, mx, pend, t0, t1, made, execing = sys.argv[1:9]
idle = sys.argv[9] if len(sys.argv) > 9 else "0"
made0 = sys.argv[10] if len(sys.argv) > 10 else made
name = "Host=postgres;Maximum Pool Size=" + mx
def row(metric, first, last=None, **labels):
    return {"metric": dict({"__name__": metric, "db_client_connection_pool_name": name}, **labels),
            "values": [[1700000000, first], [1700000060, last if last is not None else first]]}
rows = [row("db_client_connection_count", used, db_client_connection_state="used"),
        row("db_client_connection_count", idle, db_client_connection_state="idle"),
        row("db_client_connection_max", mx), row("db_client_connection_npgsql_pending_requests", "0", pend),
        row("db_client_connection_npgsql_timeouts_total", t0, t1), row("db_client_connection_npgsql_create_time_seconds_count", made0, made),
        row("db_client_operation_npgsql_executing", execing)]
json.dump({"status": "success", "data": {"resultType": "matrix", "result": rows}}, open(d + "/telemetry/metrics/database_pool_metrics.json", "w"))
PYPOOL
}

# S03/S23: 3.5 ms of CPU in a 5 s request, nothing saturated -- waiting.
report="$(build_run waiting 18 0.1 0 "")"; dir="$(dirname "$(dirname "${report}")")"
observe "${dir}" http.latency.p50 5277; observe "${dir}" efficiency.cpu_ms_per_request 3.5
classify "${dir}"
jq -e '.verdict == "wait-bound" and .confidence == "medium" and (.reason | test("spent waiting, not computing"))' "${report}" >/dev/null \
  || fail "a serialized wait was not reported as wait-bound: $(jq -c '{verdict,reason}' "${report}")"
[[ "$(verdict "$(build_run fast 18 0.1 0 "")")" != "wait-bound" ]] || fail "a 12 ms request was called wait-bound"

# S27: deadlocks outrank the DB time they cause.
report="$(build_run deadlock 40 0.5 0 "")"; dir="$(dirname "$(dirname "${report}")")"
mkdir -p "${dir}/dependencies"
printf '{"scope":"measured-window","xactCommit":465,"xactRollback":367,"deadlocks":322}\n' > "${dir}/dependencies/postgres-deadlocks-delta.json"
observe "${dir}" http.latency.p50 1022; observe "${dir}" efficiency.db_ms_per_request 2570; observe "${dir}" http.requests.total 383
classify "${dir}"
jq -e '.verdict == "db-deadlock" and (.reason | test("322 PostgreSQL deadlock")) and .resources.dbServer.deadlocked == true' "${report}" >/dev/null \
  || fail "deadlocks were not the verdict: $(jq -c '{verdict,reason}' "${report}")"

# One deadlock in 1,000 transactions is a note, not the bottleneck.
report="$(build_run stray-deadlock 40 0.5 0 "")"; dir="$(dirname "$(dirname "${report}")")"
mkdir -p "${dir}/dependencies"
printf '{"scope":"measured-window","xactCommit":999,"xactRollback":1,"deadlocks":1}\n' > "${dir}/dependencies/postgres-deadlocks-delta.json"
classify "${dir}"
jq -e '.verdict != "db-deadlock" and any(.notes[]; test("1 PostgreSQL deadlock\\(s\\) in the measured window \\(0.10% of 1000 transactions\\)"))' "${report}" >/dev/null \
  || fail "a stray deadlock became the verdict: $(jq -c '{verdict,notes}' "${report}")"

# S10/E08: sessions waiting on a row lock behind an idle-in-transaction holder
# saturate the pool; the lock is the finding, the pool its consequence.
report="$(build_run rowlock 40 0.5 0 "")"; dir="$(dirname "$(dirname "${report}")")"
mkdir -p "${dir}/dependencies"
pool "${dir}" 20 20 44 0 0 20 19
printf '%s\n' 'application_name,state,wait_event_type,wait_event,connections,blocked' 'perflab-api,active,Lock,transactionid,18,18' \
  'perflab-api,active,,,1,0' 'perflab-api,idle in transaction,Client,ClientRead,1,0' 'psql,active,,,1,0' > "${dir}/dependencies/postgres-connections-midload.csv"
printf '%s\n' 'pid,application_name,state,xact_age_ms,waiters,last_query' '412,perflab-api,idle in transaction,245,18,"UPDATE products SET stock = $1 WHERE id = $2"' \
  > "${dir}/dependencies/postgres-lock-holders-midload.csv"
classify "${dir}"
jq -e '.verdict == "db-lock-contention" and (.reason | test("18 of 19 active database sessions wait on a row lock"))
       and (.reason | test("idle in transaction for 245 ms")) and (.saturatedResources | index("dbPool"))' "${report}" >/dev/null \
  || fail "row-lock contention was not reported as the cause of the pool saturation: $(jq -c '{verdict,reason}' "${report}")"

# S09: a leaked pool reads used 0/20; the timeouts and created count explain it.
report="$(build_run leak 40 0.5 0 "")"; dir="$(dirname "$(dirname "${report}")")"
pool "${dir}" 0 20 64 48 752 20 0 1
classify "${dir}"
jq -e '.verdict == "db-pool-saturated" and (.reason | test("all 20 connections were created before the window, none since, and at most 0 in use and 1 idle"))
       and (.reason | test("704 connection acquisition timeout"))' "${report}" >/dev/null \
  || fail "a leaked pool was explained by its used gauge: $(jq -r '.reason' "${report}")"

# Normal churn re-creates connections in the window: no leak is claimed.
report="$(build_run churn 40 0.5 0 "")"; dir="$(dirname "$(dirname "${report}")")"
pool "${dir}" 5 20 3 0 0 540 5 2 500
classify "${dir}"
! jq -e '.reason | test("held outside the pool")' "${report}" >/dev/null || fail "connection churn was called a leak: $(jq -r '.reason' "${report}")"

# S21/S22: connections leased across non-database work.
report="$(build_run held 40 0.5 0 "")"; dir="$(dirname "$(dirname "${report}")")"
pool "${dir}" 2 2 46 0 1504 2 0
classify "${dir}"
notes "${report}" | grep -q "held outside database commands: the pool held 2 of its 2 connections but at most 0 commands were executing" \
  || fail "a lease held across an await was not named: $(notes "${report}")"

# P08/S05: allocation per request, gated on a real allocation rate.
report="$(build_run allocating 300 1.0 0 "")"; dir="$(dirname "$(dirname "${report}")")"
observe "${dir}" efficiency.alloc_bytes_per_request 4550000
classify "${dir}"
notes "${report}" | grep -q "allocation pressure: 4.3 MB allocated per request (peak 381 MB/s)" \
  || fail "allocation pressure was not noted: $(notes "${report}")"
jq '.data.result[0].values |= map(.[1] = "12000000")' "${dir}/telemetry/metrics/gc_allocation_rate.json" > "${dir}/rate.json" \
  && mv "${dir}/rate.json" "${dir}/telemetry/metrics/gc_allocation_rate.json"
classify "${dir}"
! notes "${report}" | grep -q "allocation pressure" || fail "12 MB/s was called allocation pressure"

# S15/S12/S14: cache health and connection churn.
report="$(build_run cache 865 1.0 0 "")"; dir="$(dirname "$(dirname "${report}")")"
mkdir -p "${dir}/dependencies"
printf 'keyspace_hits:0\r\nkeyspace_misses:51906\r\nevicted_keys:51907\r\ntotal_connections_received:51910\r\ndb0:keys=4645,expires=0,avg_ttl=0\r\ndb0_distrib_strings_sizes:32K=4645\r\n' \
  > "${dir}/dependencies/redis-info.txt"
printf '%s\n' 'queryid,calls,rows,total_exec_ms,mean_exec_ms,shared_blks_hit,shared_blks_read,temp_blks_written,query' \
  '1,51906,51906,90000.5,1.73,1,0,0,"SELECT p.id, p.name FROM products AS p WHERE p.category_id = $1"' \
  '2,1,2,2.62,2.62,498,0,0,"COPY (SELECT application_name FROM pg_stat_activity) TO STDOUT WITH CSV HEADER"' > "${dir}/dependencies/postgres-statements.csv"
observe "${dir}" http.requests.total 51906
classify "${dir}"
for expected in "the Redis cache is ineffective: 0 hits against 51906 misses" "Redis evicted 51907 keys while none of its 4645 keys has a TTL" \
    "51910 new Redis connections for 51906 requests (1.00 per request)"; do
  notes "${report}" | grep -qF "${expected}" || fail "missing dependency-health note '${expected}': $(notes "${report}")"
done
# Eviction thrash is not a stampede: no key expired.
! notes "${report}" | grep -q "stampede" || fail "eviction was called a stampede"
# S12: 2,058 misses for 13 expirations, each refreshed -- a stampede. Plain
# cache-aside (one read per miss, one miss per expiry) is not.
stampede() { # stampede <name> <hits> <misses> <expired> -> report
  local report dir; report="$(build_run "$1" 2296 1.0 0 "")"; dir="$(dirname "$(dirname "${report}")")"
  mkdir -p "${dir}/dependencies"
  printf 'keyspace_hits:%s\r\nkeyspace_misses:%s\r\nexpired_keys:%s\r\nevicted_keys:0\r\n' "$2" "$3" "$4" > "${dir}/dependencies/redis-info.txt"
  printf '%s\n' 'queryid,calls,rows,total_exec_ms,mean_exec_ms,shared_blks_hit,shared_blks_read,temp_blks_written,query' \
    "1,$3,$3,900.5,0.4,1,0,0,\"SELECT p.id FROM products AS p WHERE p.category_id = \$1\"" > "${dir}/dependencies/postgres-statements.csv"
  classify "${dir}"; printf '%s' "${report}"
}
notes "$(stampede stampede 136638 2058 13)" | grep -q "cache stampede: 2058 misses for 13 expired keys (~158 per expiry)" \
  || fail "a stampede was not named"
! notes "$(stampede cache-aside 9000 1000 1000)" | grep -q "stampede" || fail "plain cache-aside was called a stampede"

# P11: ~500 exceptions per request.
report="$(build_run exceptions 8 0.5 0 "")"; dir="$(dirname "$(dirname "${report}")")"
printf '{"status":"success","data":{"resultType":"matrix","result":[{"metric":{"error_type":"System.InvalidOperationException"},"values":[[1700000000,"4000"]]},{"metric":{"error_type":"System.FormatException"},"values":[[1700000000,"20"]]}]}}\n' \
  > "${dir}/telemetry/metrics/exceptions.json"
classify "${dir}"
notes "${report}" | grep -q "exception pressure: ~502 exceptions per request (peak 4020/s, mostly System.InvalidOperationException)" \
  || fail "exception pressure was not noted: $(notes "${report}")"

# S26/S13: dependency time from span metrics, by the system a client span calls.
spans() { # spans <dir> <file> <server> <kind:system-label=value:rate>...
  "${PYTHON}" - "$@" <<'PYSPANS'
import json, sys
d, name, server = sys.argv[1:4]
rows = [{"metric": {"span_kind": "SPAN_KIND_SERVER"}, "values": [[1700000000 + i * 5, server] for i in range(12)]}]
for spec in sys.argv[4:]:
    kind, label, rate = spec.split(":")
    key, value = label.split("=")
    rows.append({"metric": {"span_kind": kind, key: value}, "values": [[1700000000 + i * 5, rate] for i in range(12)]})
json.dump({"status": "success", "data": {"resultType": "matrix", "result": rows}}, open(d + "/telemetry/metrics/" + name + ".json", "w"))
PYSPANS
}
report="$(build_run upstream-time 1217 0.4 0 "")"; dir="$(dirname "$(dirname "${report}")")"
observe "${dir}" http.latency.p50 104; observe "${dir}" efficiency.cpu_ms_per_request 0.1
spans "${dir}" dependency_time 126 SPAN_KIND_CLIENT:server_address=upstream:122 SPAN_KIND_CLIENT:server_address=lgtm:40 SPAN_KIND_CLIENT:db_system=postgresql:120
spans "${dir}" dependency_calls 1217 SPAN_KIND_CLIENT:server_address=upstream:1217
mkdir -p "${dir}/environment/measurement-start"
printf '[{"telemetryExporterAuthority":"lgtm:4318"}]\n' > "${dir}/environment/measurement-start/resource-limits.json"
classify "${dir}"
jq -e '.verdict == "dependency-bound-http" and (.reason | test("HTTP upstream upstream spans cover ~97% of server time \\(1.0 calls per request\\)"))
       and .resources.dependency.system == "http:upstream"' "${report}" >/dev/null \
  || fail "an HTTP upstream holding the request was not named: $(jq -c '{verdict,reason,dependency:.resources.dependency}' "${report}")"
report="$(build_run redis-time 980 7.8 0 "")"; dir="$(dirname "$(dirname "${report}")")"
spans "${dir}" dependency_time 50 SPAN_KIND_CLIENT:db_system=redis:40
spans "${dir}" dependency_calls 980 SPAN_KIND_CLIENT:db_system=redis:98000
classify "${dir}"
jq -e '.verdict == "cpu-bound" and any(.notes[]; test("redis spans cover ~80% of server time \\(100.0 calls per request\\), though cpu-bound ranks higher"))
       and any(.notes[]; test("dependency amplification: each request makes ~100 redis calls"))' "${report}" >/dev/null \
  || fail "dependency time behind a CPU verdict was not noted: $(jq -c '{verdict,notes}' "${report}")"

# E01: a 12 s window read against a 20 s rate lookback is not classified from rates.
report="$(build_run short-window 300 7.8 0 "")"; dir="$(dirname "$(dirname "${report}")")"
[[ "$(verdict "${report}")" == "cpu-bound" ]] || fail "the short-window fixture should be cpu-bound before the guard"
printf '{"rateWindowSeconds":20,"measuredSeconds":12,"established":false}\n' > "${dir}/telemetry/rate-window.json"
classify "${dir}"
jq -e '.verdict != "cpu-bound" and .verdict != "wait-bound" and .resources.cpu.utilizationPct == null and .resources.gc.pauseFractionPeak == null
       and any(.notes[]; test("measured window \\(12 s\\) is shorter than the 20 s rate window"))' "${report}" >/dev/null \
  || fail "rates reaching before a short window were classified: $(jq -c '{verdict,notes}' "${report}")"

# S02: a pool grown far past the cores at low CPU is threads blocked on work
# (sync over async); the queue may only spike once the pool has grown.
report="$(build_run blocked 294 0.48 0 "")"; dir="$(dirname "$(dirname "${report}")")"
for f in thread_count:140 cpu_count:1; do
  jq --arg v "${f#*:}" '.data.result[0].values |= map(.[1] = $v)' "${dir}/telemetry/metrics/${f%%:*}.json" > "${dir}/m.json" \
    && mv "${dir}/m.json" "${dir}/telemetry/metrics/${f%%:*}.json"
done
observe "${dir}" http.latency.p50 108
classify "${dir}"
jq -e '.verdict == "threadpool-starved" and .confidence == "high" and (.reason | test("grew to 140 threads on 1 core"))
       and .resources.threadPool.blockedThreads == true and (.saturatedResources | index("threadPool"))' "${report}" >/dev/null \
  || fail "blocked pool threads were not named: $(jq -c '{verdict,confidence,reason}' "${report}")"
jq '.data.result[0].values |= map(.[1] = "5")' "${dir}/telemetry/metrics/thread_count.json" > "${dir}/m.json" && mv "${dir}/m.json" "${dir}/telemetry/metrics/thread_count.json"
classify "${dir}"
[[ "$(verdict "${report}")" != "threadpool-starved" ]] || fail "five threads on one core were called blocked"

# S07: a query per item of a list (N+1), each on its own leased connection.
report="$(build_run amplified 50 0.5 0 "")"; dir="$(dirname "$(dirname "${report}")")"
mkdir -p "${dir}/dependencies"
printf '%s\n' 'queryid,calls,rows,total_exec_ms,mean_exec_ms,shared_blks_hit,shared_blks_read,temp_blks_written,query' \
  '1,150000,1500000,9000.5,0.06,1,0,0,"SELECT o.product_id FROM order_items AS o WHERE o.order_id = $1"' \
  '2,3000,150000,1300.2,0.43,1,0,0,"SELECT o.id FROM orders AS o WHERE o.customer_id = $1"' \
  '3,153000,0,90.1,0.00,0,0,0,DISCARD ALL' > "${dir}/dependencies/postgres-statements.csv"
observe "${dir}" http.requests.total 3000
classify "${dir}"
notes "${report}" | grep -qF 'query amplification: "SELECT o.product_id FROM order_items AS o WHERE o.order_id = $1" ran 50 times per request (150000 calls for 3000 requests), with 51 connection resets (DISCARD ALL) per request' \
  || fail "query amplification was not stated: $(notes "${report}")"

# Sampled spans per entry request (local lab, sampler ratio 0.25): S10 read 0.2
# publishes per request against the unsampled rate; S26 served its own upstream,
# two server spans per request.
report="$(build_run entry 1000 1.0 0 "")"; dir="$(dirname "$(dirname "${report}")")"
printf '{"target":"local","traceSampler":"parentbased_traceidratio","traceSamplerArg":"0.25"}\n' > "${dir}/manifest.json"
spans "${dir}" dependency_time 25 SPAN_KIND_PRODUCER:messaging_system=rabbitmq:20
spans "${dir}" dependency_calls 500 SPAN_KIND_PRODUCER:messaging_system=rabbitmq:250
classify "${dir}"
jq -e '.resources.dependency.callsPerRequest == 1 and .resources.dependency.callsBasis == "entry-requests" and .resources.dependency.msPerRequest == 80
       and .resources.dependency.nestedServerRequestsPerRequest == 1 and (.reason | test("also served 1.0 nested request"))' "${report}" >/dev/null \
  || fail "spans were not counted per entry request: $(jq -c '{dependency:.resources.dependency,notes}' "${report}")"

# S16: connections and channels opened per publish; nothing when the broker
# restarted inside the window.
report="$(build_run broker 1400 1.0 0 "")"; dir="$(dirname "$(dirname "${report}")")"
mkdir -p "${dir}/dependencies"
printf 'rabbitmq_connections_opened_total 50\nrabbitmq_channels_opened_total 26\n' > "${dir}/dependencies/rabbitmq-broker-metrics-preload.txt"
printf 'rabbitmq_connections_opened_total 84050\nrabbitmq_channels_opened_total 84026\n' > "${dir}/dependencies/rabbitmq-broker-metrics.txt"
observe "${dir}" http.requests.total 84000
classify "${dir}"
notes "${report}" | grep -qF "84000 RabbitMQ connections and 84000 channels opened for 84000 requests (1.00 per request)" \
  || fail "broker churn was not stated: $(notes "${report}")"
printf '{"scope":"broker-restarted"}\n' > "${dir}/analysis/async-reconciliation.json"
classify "${dir}"
! notes "${report}" | grep -q "RabbitMQ connections" || fail "churn was computed across a broker restart"

# S23: the wait is the lab's own pool, which the application measures.
report="$(build_run app-pool 13 0.1 0 "")"; dir="$(dirname "$(dirname "${report}")")"
observe "${dir}" http.latency.p50 5000; observe "${dir}" efficiency.cpu_ms_per_request 2.9
"${PYTHON}" - "${dir}" <<'PYAPP'
import json, sys
labels = {"pool_name": "redis-multiplexer", "pool_configured_size": "1"}
def row(name, first, last):
    return {"metric": dict({"__name__": name}, **labels), "values": [[1700000000, first], [1700000060, last]]}
rows = [row("perflab_pool_wait_duration_milliseconds_sum", "1095784", "4857492"),
        row("perflab_pool_wait_duration_milliseconds_count", "255", "1051"),
        row("perflab_pool_active_leases", "0", "1")]
json.dump({"status": "success", "data": {"resultType": "matrix", "result": rows}}, open(sys.argv[1] + "/telemetry/metrics/application_metrics.json", "w"))
PYAPP
classify "${dir}"
jq -e '.verdict == "wait-bound" and (.reason | test("the application pool \"redis-multiplexer\" \\(configured size 1\\): 796 waits in the window averaged 4726 ms \\(95% of the median\\)"))
       and .resources.appPool.holdsWait == true' "${report}" >/dev/null \
  || fail "the pool holding the wait was not named: $(jq -c '{verdict,reason}' "${report}")"

# S24/S26: connections the application holds open.
report="$(build_run footprint 400 1.0 0 "" 0.001 128 128)"; dir="$(dirname "$(dirname "${report}")")"
mkdir -p "${dir}/dependencies"
printf 'connected_clients:34\r\n' > "${dir}/dependencies/redis-clients-midload.txt"
jq '.data.result = [(.data.result[0] | .metric = {service_instance_id: "api"}), (.data.result[0] | .metric = {service_instance_id: "worker"})]' \
  "${dir}/telemetry/metrics/process_cpu.json" > "${dir}/m.json" && mv "${dir}/m.json" "${dir}/telemetry/metrics/process_cpu.json"
classify "${dir}"
for expected in "Redis held 34 client connections mid-load for 2 application process(es)" "the application held 128 open connections to upstream at peak"; do
  notes "${report}" | grep -qF "${expected}" || fail "missing footprint note '${expected}': $(notes "${report}")"
done

# S27: exceptions per request from the window means, the peak beside it.
report="$(build_run exception-mean 10 0.5 0 "")"; dir="$(dirname "$(dirname "${report}")")"
printf '{"status":"success","data":{"resultType":"matrix","result":[{"metric":{"error_type":"PostgresException"},"values":[[1700000000,"400"],[1700000005,"100"]]}]}}\n' \
  > "${dir}/telemetry/metrics/exceptions.json"
classify "${dir}"
notes "${report}" | grep -qF "exception pressure: ~25 exceptions per request (peak 400/s" \
  || fail "exceptions per request mixed the peak with the mean: $(notes "${report}")"

# E03: the database holds the request without a pool queue: its statement and
# the rows its plan reads only to discard them.
report="$(build_run deep-offset 80 0.1 0 "")"; dir="$(dirname "$(dirname "${report}")")"
mkdir -p "${dir}/dependencies"
observe "${dir}" efficiency.db_ms_per_request 8
printf '%s\n' 'queryid,calls,rows,total_exec_ms,mean_exec_ms,shared_blks_hit,shared_blks_read,temp_blks_written,query' \
  '1,4801,120025,4428.6,0.92,1,0,0,"SELECT p.id FROM products AS p WHERE p.is_active ORDER BY p.id LIMIT $1 OFFSET $2"' > "${dir}/dependencies/postgres-statements.csv"
printf '{"plan":[{"Plan":{"Node Type":"Limit","Actual Rows":25,"Actual Loops":1,"Plans":[{"Node Type":"Index Scan","Relation Name":"products","Actual Rows":12500,"Actual Loops":1,"Rows Removed by Filter":0}]}}]}\n' \
  > "${dir}/dependencies/postgres-query-plan.json"
classify "${dir}"
for expected in 'the statement with the most database time is "SELECT p.id FROM products AS p WHERE p.is_active ORDER BY p.id LIMIT $1 OFFSET $2" (4801 calls, mean 0.92 ms)' \
    "reads 12500 rows to return 25 (Index Scan on products)"; do
  notes "${report}" | grep -qF "${expected}" || fail "missing database note '${expected}': $(notes "${report}")"
done

# E12/E14: a full pool reads its connections as used plus idle (a returned
# connection counts idle until a waiter takes it); beside a saturated CPU, with
# the database executing a sliver of each lease, the queue follows the CPU.
report="$(build_run starved-client 3600 7.8 0 "")"; dir="$(dirname "$(dirname "${report}")")"
mkdir -p "${dir}/dependencies"
pool "${dir}" 5 20 214 0 0 20 18 15
observe "${dir}" efficiency.db_ms_per_request 2.4; observe "${dir}" http.requests.total 216000
printf '%s\n' 'queryid,calls,rows,total_exec_ms,mean_exec_ms,shared_blks_hit,shared_blks_read,temp_blks_written,query' \
  '1,216000,216000,2160.0,0.01,1,0,0,"SELECT u.id FROM users AS u WHERE u.id = $1"' > "${dir}/dependencies/postgres-statements.csv"
classify "${dir}"
jq -e '.verdict == "cpu-bound+db-pool-saturated" and .resources.dbPool.connectionsPeak == 20
       and any(.notes[]; test("the pool queue follows the saturated CPU: the database server executes 0.01 ms of the 2.4 ms"))
       and any(.notes[]; test("round trips and processing in the client"))' "${report}" >/dev/null \
  || fail "a pool queue behind a starved client was not ranked after the CPU: $(jq -c '{verdict,notes}' "${report}")"

# P02: requests the generator counted failed that the application never saw.
report="$(build_run unreached 3600 0.2 0 "")"; dir="$(dirname "$(dirname "${report}")")"
observe "${dir}" http.requests.total 36009; observe "${dir}" http.error_rate 0.95
printf '{"status":"success","data":{"resultType":"matrix","result":[{"metric":{"__name__":"http_server_request_duration_seconds_count","http_response_status_code":"101"},"values":[[1700000000,"0"],[1700000060,"1800"]]}]}}\n' \
  > "${dir}/telemetry/metrics/request_duration.json"
classify "${dir}"
jq -e '.confidence == "low" and any(.notes[]; test("34209 of 36009 requests never reached the application \\(it recorded 1800\\)"))' "${report}" >/dev/null \
  || fail "failures before the application were not attributed: $(jq -c '{confidence,notes}' "${report}")"

# A fault inside the window explains the errors; nothing reads OVERLOADED.
report="$(build_run faulted 1400 0.5 0 "")"; dir="$(dirname "$(dirname "${report}")")"
mkdir -p "${dir}/benchmark"
printf '{"action":"kill","service":"rabbitmq","applied":true,"restored":true}\n' > "${dir}/benchmark/fault-proof.json"
observe "${dir}" http.error_rate 0.09
classify "${dir}"
jq -e 'any(.notes[]; test("requests failed while a dependency fault was injected")) and all(.notes[]; contains("OVERLOADED") | not)' "${report}" >/dev/null \
  || fail "the fault was not named as the cause of the errors: $(notes "${report}")"

echo "bottleneck classifier rule tests passed"
