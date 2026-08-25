#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_command curl
require_command jq
require_command docker

artifact_dir="${1:?Usage: capture-evidence.sh <artifact-directory>}"
manifest="${artifact_dir}/manifest.json"
if [[ ! -f "${manifest}" ]]; then
  echo "Manifest not found: ${manifest}" >&2
  exit 1
fi

run_id="$(jq -r '.runId' "${manifest}")"
telemetry_run_id="$(jq -r '.telemetryRunId // .runId' "${manifest}")"
scenario_id="$(jq -r '.scenarioId' "${manifest}")"
load_generator="$(jq -r '.workload.loadGenerator // "wrk"' "${manifest}")"
start_epoch="$(jq -r '.startedEpoch' "${manifest}")"
end_epoch="$(date -u +%s)"

mkdir -p "${artifact_dir}/telemetry/metrics" "${artifact_dir}/telemetry/traces/details" "${artifact_dir}/telemetry/logs" "${artifact_dir}/dependencies" "${artifact_dir}/source"

capture_prometheus_query() {
  local output_name="$1"
  local query="$2"
  curl -fsS --max-time 20 --get \
    --data-urlencode "query=${query}" \
    http://127.0.0.1:9090/api/v1/query \
    > "${artifact_dir}/telemetry/metrics/${output_name}.json" || true
}

# Gauges and rates must be captured over the run window, not sampled once after
# the load stops. An instant query taken at capture time reports an idle process
# and systematically hides the peak the metric exists to show: thread-pool
# queueing, heap growth, and CPU saturation are all over by then. Cumulative
# perflab_* counters stay on the instant query above, where a single read at the
# end is already the run total.
capture_prometheus_range() {
  local output_name="$1"
  local query="$2"
  curl -fsS --max-time 30 --get \
    --data-urlencode "query=${query}" \
    --data-urlencode "start=${start_epoch}" \
    --data-urlencode "end=${end_epoch}" \
    --data-urlencode "step=5" \
    http://127.0.0.1:9090/api/v1/query_range \
    > "${artifact_dir}/telemetry/metrics/${output_name}.json" || true
}

capture_prometheus_range process_cpu 'rate(dotnet_process_cpu_time_seconds_total{job=~"perflab-.*"}[1m])'
capture_prometheus_range working_set 'dotnet_process_memory_working_set_bytes{job=~"perflab-.*"}'
capture_prometheus_range gc_heap 'dotnet_gc_last_collection_heap_size_bytes{job=~"perflab-.*"}'
capture_prometheus_range thread_pool_queue 'dotnet_thread_pool_queue_length_total{job=~"perflab-.*"}'
capture_prometheus_range request_duration 'http_server_request_duration_seconds_count{job=~"perflab-.*"}'
# dotnet_gc_last_collection_heap_size_bytes above only changes when a collection
# happens, which made it report the same stale value for several scenarios in a
# row. These two move continuously and are what memory-growth claims should
# rest on.
capture_prometheus_range gc_allocation_rate 'rate(dotnet_gc_heap_allocated_bytes_total{job=~"perflab-.*"}[1m])'
capture_prometheus_range gc_committed 'dotnet_gc_last_collection_memory_committed_size_bytes{job=~"perflab-.*"}'
capture_prometheus_range gc_collections 'dotnet_gc_collections_total{job=~"perflab-.*"}'
capture_prometheus_range gc_pause 'rate(dotnet_gc_pause_time_seconds_total{job=~"perflab-.*"}[1m])'
capture_prometheus_query scenario_executions "perflab_scenario_executions_total{perf_run_id=\"${telemetry_run_id}\"}"
capture_prometheus_query application_metrics "{__name__=~\"perflab_.*\",perf_run_id=\"${telemetry_run_id}\"}"
capture_prometheus_query pool_metrics "{__name__=~\"perflab_pool_.*\",perf_run_id=\"${telemetry_run_id}\"}"

service_instance_regex="$(
  jq -r '
    [.data.result[]? | (.metric.service_instance_id // .metric.instance // empty)]
    | unique
    | join("|")
  ' "${artifact_dir}/telemetry/metrics/application_metrics.json"
)"
service_instance_regex="${service_instance_regex:-__no_correlated_service_instance__}"

capture_prometheus_query database_pool_metrics "{__name__=~\"(db_client_connection_.*|db_client_operation_npgsql_.*|npgsql_.*)\",service_instance_id=~\"${service_instance_regex}\"}"
capture_prometheus_query http_client_metrics "{__name__=~\"http_client_.*\",service_instance_id=~\"${service_instance_regex}\"}"

trace_query="{ resource.service.name =~ \"perflab-(api|worker)\" && resource.perf.run.id = \"${telemetry_run_id}\" }"
trace_search_file="${artifact_dir}/telemetry/traces/search.json"
for trace_attempt in $(seq 1 6); do
  curl -fsS --max-time 20 --get \
    --data-urlencode "q=${trace_query}" \
    --data-urlencode "start=${start_epoch}" \
    --data-urlencode "end=${end_epoch}" \
    --data-urlencode "limit=200" \
    http://127.0.0.1:3200/api/search \
    > "${trace_search_file}" || true

  if jq -e '.traces | length > 0' "${trace_search_file}" >/dev/null 2>&1; then
    break
  fi

  sleep 5
done

if jq -e '.traces | length > 0' "${trace_search_file}" >/dev/null 2>&1; then
  trace_detail_failures=0
  while IFS= read -r trace_id; do
    trace_detail_file="${artifact_dir}/telemetry/traces/details/${trace_id}.json"
    # The redirect creates the file before curl runs, so a failed fetch left a
    # zero-byte artifact indistinguishable from a captured trace. Stage the
    # fetch and publish it only when curl actually succeeded.
    if curl -fsS --max-time 20 "http://127.0.0.1:3200/api/traces/${trace_id}" \
      > "${trace_detail_file}.tmp" 2>/dev/null; then
      mv "${trace_detail_file}.tmp" "${trace_detail_file}"
    else
      rm -f "${trace_detail_file}.tmp"
      trace_detail_failures=$((trace_detail_failures + 1))
    fi
  done < <(jq -r '.traces | sort_by(.durationMs // 0) | reverse | .[:10][] | .traceID' "${trace_search_file}")

  if [[ "${trace_detail_failures}" -gt 0 ]]; then
    echo "WARNING: ${trace_detail_failures} trace detail fetch(es) failed; this evidence package is INCOMPLETE." >&2
  fi
fi

# The previous query appended |= "<runId>", which filters on message TEXT. The
# run id is a resource attribute, not part of any message, so the only line
# that ever matched was the startup banner that prints it literally: a
# scenario emitting ~52k log lines captured exactly one. The run window below
# already scopes the query to this scenario, because each scenario runs in a
# freshly recreated container, so no run-id filter is needed.
log_query="{service_name=~\"perflab-(api|worker)\"}"
# Loki needs time to ingest and flush a burst, and a high-volume scenario can
# still be indexing when capture starts: a scenario emitting ~988k lines returned
# an empty result here while the same query answered normally moments later.
# Tempo already retries for this reason; the log query now does too, and each
# attempt writes to a temp file so a timeout cannot leave a truncated artifact.
# limit=5000 exceeded Loki's 4 MiB internal gRPC message cap on verbose
# scenarios: the query failed with HTTP 500 "ResourceExhausted ... larger than
# max (7317305 vs 4194304)" after ~18s, all six attempts failed the same way,
# and the pre-truncated artifact was left at zero bytes while the run still
# reported success. Measured on this stack: 5000 -> 500 (7.3MB), 3000 -> 500,
# 2000 -> 200 (2.92MB in 0.30s), 1000 -> 200 (1.46MB).
log_file="${artifact_dir}/telemetry/logs/query-range.json"
log_tmp="${log_file}.tmp"
: > "${log_file}"
for log_attempt in $(seq 1 6); do
  if curl -fsS --max-time 30 --get \
    --data-urlencode "query=${log_query}" \
    --data-urlencode "start=${start_epoch}000000000" \
    --data-urlencode "end=${end_epoch}000000000" \
    --data-urlencode "limit=2000" \
    http://127.0.0.1:3100/loki/api/v1/query_range \
    > "${log_tmp}" 2>/dev/null; then
    mv "${log_tmp}" "${log_file}"
    if jq -e '[.data.result[]?.values[]?] | length > 0' "${log_file}" >/dev/null 2>&1; then
      break
    fi
  fi
  rm -f "${log_tmp}"
  sleep 5
done

# An empty artifact must not be mistaken for a quiet run. A silently empty
# capture is worse than a loud failure because it makes an incomplete package
# look diagnosable.
if ! jq -e '[.data.result[]?.values[]?] | length > 0' "${log_file}" >/dev/null 2>&1; then
  echo "WARNING: log capture produced no entries at ${log_file}; treat these logs as MISSING, not as evidence of a quiet run." >&2
fi

docker compose -f "${repo_root}/compose.yaml" exec -T postgres \
  psql -U perflab -d perflab -c \
  "COPY (SELECT queryid, calls, rows, round(total_exec_time::numeric,2) AS total_exec_ms, round(mean_exec_time::numeric,2) AS mean_exec_ms, shared_blks_hit, shared_blks_read, temp_blks_written, left(regexp_replace(query, '\s+', ' ', 'g'), 300) AS query FROM pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname='perflab') ORDER BY total_exec_time DESC LIMIT 50) TO STDOUT WITH CSV HEADER" \
  > "${artifact_dir}/dependencies/postgres-statements.csv"

docker compose -f "${repo_root}/compose.yaml" exec -T postgres \
  psql -U perflab -d perflab -c \
  "COPY (SELECT pid, application_name, wait_event_type, wait_event, state, backend_start, state_change, left(query,300) AS query FROM pg_stat_activity WHERE datname='perflab' ORDER BY pid) TO STDOUT WITH CSV HEADER" \
  > "${artifact_dir}/dependencies/postgres-activity.csv"

docker compose -f "${repo_root}/compose.yaml" exec -T postgres \
  psql -U perflab -d perflab -c \
  "COPY (SELECT application_name, state, count(*) AS connections, min(backend_start) AS oldest_backend FROM pg_stat_activity WHERE datname='perflab' GROUP BY application_name, state ORDER BY application_name, state) TO STDOUT WITH CSV HEADER" \
  > "${artifact_dir}/dependencies/postgres-connections.csv"

docker compose -f "${repo_root}/compose.yaml" exec -T postgres \
  psql -U perflab -d perflab -t -A -c \
  "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT id, created_at, total, status FROM orders WHERE customer_id=1 ORDER BY created_at DESC, id DESC OFFSET 2475 LIMIT 25" \
  > "${artifact_dir}/dependencies/postgres-order-plan.json"

docker compose -f "${repo_root}/compose.yaml" exec -T redis redis-cli INFO all \
  > "${artifact_dir}/dependencies/redis-info.txt"
docker compose -f "${repo_root}/compose.yaml" exec -T redis redis-cli SLOWLOG GET 128 \
  > "${artifact_dir}/dependencies/redis-slowlog.txt"
docker compose -f "${repo_root}/compose.yaml" exec -T redis redis-cli LATENCY LATEST \
  > "${artifact_dir}/dependencies/redis-latency.txt"

curl -fsS --max-time 15 -u "perflab:${RABBITMQ_PASSWORD:-perflab}" \
  http://127.0.0.1:15672/api/queues \
  > "${artifact_dir}/dependencies/rabbitmq-queues.json" || true

curl -fsS --max-time 15 http://127.0.0.1:18323/processes \
  > "${artifact_dir}/runtime/processes.json" || true

docker compose -f "${repo_root}/compose.yaml" exec -T api \
  sh -c 'cat /proc/net/tcp /proc/net/tcp6' \
  > "${artifact_dir}/dependencies/api-net-tcp.txt" 2>/dev/null || true

curl -fsS --max-time 15 -u "perflab:${RABBITMQ_PASSWORD:-perflab}" \
  http://127.0.0.1:15672/api/connections \
  > "${artifact_dir}/dependencies/rabbitmq-connections.json" || true

curl -fsS --max-time 15 -u "perflab:${RABBITMQ_PASSWORD:-perflab}" \
  http://127.0.0.1:15672/api/channels \
  > "${artifact_dir}/dependencies/rabbitmq-channels.json" || true

curl -fsS --max-time 15 http://127.0.0.1:15692/metrics 2>/dev/null \
  | grep -E '^rabbitmq_(connections|channels)' \
  > "${artifact_dir}/dependencies/rabbitmq-broker-metrics.txt" || true

docker compose -f "${repo_root}/compose.yaml" ps --format json \
  | jq -s '.' \
  > "${artifact_dir}/dependencies/docker-compose-ps.json"

{
  dotnet --info
  docker version
  docker compose version
  wrk --version
  k6 version
  claude --version
} > "${artifact_dir}/source/tool-versions.txt" 2>&1 || true

if git -C "${repo_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "${repo_root}" status --short > "${artifact_dir}/source/git-status.txt"
  git -C "${repo_root}" diff --stat > "${artifact_dir}/source/git-diff-stat.txt"
fi

if [[ "${load_generator}" == "wrk" ]]; then
  wrk_file="${artifact_dir}/benchmark/wrk.txt"
  requests_per_second="$(awk '/Requests\/sec:/ {print $2}' "${wrk_file}" | tail -1)"
  p50="$(awk '$1 == "50%" {print $2}' "${wrk_file}" | tail -1)"
  p90="$(awk '$1 == "90%" {print $2}' "${wrk_file}" | tail -1)"
  p99="$(awk '$1 == "99%" {print $2}' "${wrk_file}" | tail -1)"
  non_2xx="$(awk '/Non-2xx or 3xx responses:/ {print $5}' "${wrk_file}" | tail -1)"
  requests_per_second="${requests_per_second:-0}"
  non_2xx="${non_2xx:-0}"

  # wrk prints latency as a unit-suffixed string such as "1.23ms" or "1.05s",
  # so these percentiles stay strings tagged as wrk-duration.
  jq -n \
    --arg runId "${run_id}" \
    --arg telemetryRunId "${telemetry_run_id}" \
    --arg scenarioId "${scenario_id}" \
    --arg loadGenerator "${load_generator}" \
    --arg p50 "${p50:-unknown}" \
    --arg p90 "${p90:-unknown}" \
    --arg p99 "${p99:-unknown}" \
    --argjson requestsPerSecond "${requests_per_second}" \
    --argjson non2xx "${non_2xx}" \
    '{runId:$runId,telemetryRunId:$telemetryRunId,scenarioId:$scenarioId,loadGenerator:$loadGenerator,observations:[{name:"http.requests_per_second",value:$requestsPerSecond,unit:"request/s",source:"benchmark/wrk.txt"},{name:"http.latency.p50",value:$p50,unit:"wrk-duration",source:"benchmark/wrk.txt"},{name:"http.latency.p90",value:$p90,unit:"wrk-duration",source:"benchmark/wrk.txt"},{name:"http.latency.p99",value:$p99,unit:"wrk-duration",source:"benchmark/wrk.txt"},{name:"http.responses.non_2xx_3xx",value:$non2xx,unit:"response",source:"benchmark/wrk.txt"}]}' \
    > "${artifact_dir}/facts.json"
else
  k6_summary_file="${artifact_dir}/benchmark/k6-summary.json"
  if [[ ! -s "${k6_summary_file}" ]]; then
    echo "k6 summary export not found or empty: ${k6_summary_file}" >&2
    exit 1
  fi

  # k6 reports trend statistics as floating-point milliseconds, so these
  # percentiles are numeric and directly comparable between k6 runs. They are
  # not comparable to a wrk-duration string from a wrk run.
  #
  # A k6 counter that never fires is omitted from the export entirely rather
  # than exported as zero, hence the "// 0" fallbacks. non_2xx_3xx and
  # transport_errors come from the lab's own counters in
  # scripts/k6/scenario.js because the built-in http_req_failed rate merges an
  # HTTP error response together with a connection-level failure.
  jq -n \
    --arg runId "${run_id}" \
    --arg telemetryRunId "${telemetry_run_id}" \
    --arg scenarioId "${scenario_id}" \
    --arg loadGenerator "${load_generator}" \
    --slurpfile summary "${k6_summary_file}" \
    '($summary[0].metrics // {}) as $m
    | {runId:$runId,telemetryRunId:$telemetryRunId,scenarioId:$scenarioId,loadGenerator:$loadGenerator,observations:[{name:"http.requests_per_second",value:($m.http_reqs.rate // 0),unit:"request/s",source:"benchmark/k6-summary.json"},{name:"http.latency.p50",value:($m.http_req_duration["p(50)"]),unit:"ms",source:"benchmark/k6-summary.json"},{name:"http.latency.p90",value:($m.http_req_duration["p(90)"]),unit:"ms",source:"benchmark/k6-summary.json"},{name:"http.latency.p99",value:($m.http_req_duration["p(99)"]),unit:"ms",source:"benchmark/k6-summary.json"},{name:"http.responses.non_2xx_3xx",value:($m.perflab_http_non_2xx_3xx.count // 0),unit:"response",source:"benchmark/k6-summary.json"},{name:"http.transport_errors",value:($m.perflab_http_transport_errors.count // 0),unit:"error",source:"benchmark/k6-summary.json"},{name:"http.requests.total",value:($m.http_reqs.count // 0),unit:"request",source:"benchmark/k6-summary.json"}]}' \
    > "${artifact_dir}/facts.json"
fi

temporary_manifest="${manifest}.tmp"
jq \
  --arg completedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson measurementEndedEpoch "${end_epoch}" \
  --argjson completedEpoch "$(date -u +%s)" \
  '. + {measurementEndedEpoch:$measurementEndedEpoch,completedAt:$completedAt,completedEpoch:$completedEpoch,status:"captured"}' \
  "${manifest}" > "${temporary_manifest}"
mv "${temporary_manifest}" "${manifest}"
