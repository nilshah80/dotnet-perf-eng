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
  python3 - "${dir}" "${rps}" "${cores}" "${queue}" "${growth}" "${upwait}" "${upactive}" "${upconns}" <<'PY'
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
notes "${starved_gen}" | grep -q 'offered load exceeded served throughput' \
  || fail "the note does not say the offered load was never delivered"

echo "bottleneck classifier rule tests passed"
