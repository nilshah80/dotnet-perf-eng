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
start_epoch="$(jq -r '.startedEpoch' "${manifest}")"
end_epoch="$(date -u +%s)"

mkdir -p "${artifact_dir}/telemetry/metrics" "${artifact_dir}/telemetry/traces/details" "${artifact_dir}/telemetry/logs" "${artifact_dir}/dependencies" "${artifact_dir}/source"

capture_prometheus_query() {
  local output_name="$1"
  local query="$2"
  curl -fsS --get \
    --data-urlencode "query=${query}" \
    http://127.0.0.1:9090/api/v1/query \
    > "${artifact_dir}/telemetry/metrics/${output_name}.json" || true
}

capture_prometheus_query process_cpu 'rate(dotnet_process_cpu_time_seconds_total{job=~"perflab-.*"}[1m])'
capture_prometheus_query working_set 'dotnet_process_memory_working_set_bytes{job=~"perflab-.*"}'
capture_prometheus_query gc_heap 'dotnet_gc_last_collection_heap_size_bytes{job=~"perflab-.*"}'
capture_prometheus_query thread_pool_queue 'dotnet_thread_pool_queue_length_total{job=~"perflab-.*"}'
capture_prometheus_query request_duration 'http_server_request_duration_seconds_count{job=~"perflab-.*"}'
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
  curl -fsS --get \
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
  while IFS= read -r trace_id; do
    curl -fsS "http://127.0.0.1:3200/api/traces/${trace_id}" \
      > "${artifact_dir}/telemetry/traces/details/${trace_id}.json" || true
  done < <(jq -r '.traces | sort_by(.durationMs // 0) | reverse | .[:10][] | .traceID' "${trace_search_file}")
fi

log_query="{service_name=~\"perflab-(api|worker)\"} |= \"${telemetry_run_id}\""
curl -fsS --get \
  --data-urlencode "query=${log_query}" \
  --data-urlencode "start=${start_epoch}000000000" \
  --data-urlencode "end=${end_epoch}000000000" \
  --data-urlencode "limit=5000" \
  http://127.0.0.1:3100/loki/api/v1/query_range \
  > "${artifact_dir}/telemetry/logs/query-range.json" || true

docker compose -f "${repo_root}/compose.yaml" exec -T postgres \
  psql -U perflab -d perflab -c \
  "COPY (SELECT queryid, calls, rows, round(total_exec_time::numeric,2) AS total_exec_ms, round(mean_exec_time::numeric,2) AS mean_exec_ms, shared_blks_hit, shared_blks_read, temp_blks_written FROM pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname='perflab') ORDER BY total_exec_time DESC LIMIT 50) TO STDOUT WITH CSV HEADER" \
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

curl -fsS -u "perflab:${RABBITMQ_PASSWORD:-perflab}" \
  http://127.0.0.1:15672/api/queues \
  > "${artifact_dir}/dependencies/rabbitmq-queues.json" || true

curl -fsS http://127.0.0.1:52323/processes \
  > "${artifact_dir}/runtime/processes.json" || true

docker compose -f "${repo_root}/compose.yaml" exec -T api \
  sh -c 'cat /proc/net/tcp /proc/net/tcp6' \
  > "${artifact_dir}/dependencies/api-net-tcp.txt" 2>/dev/null || true

curl -fsS -u "perflab:${RABBITMQ_PASSWORD:-perflab}" \
  http://127.0.0.1:15672/api/connections \
  > "${artifact_dir}/dependencies/rabbitmq-connections.json" || true

curl -fsS -u "perflab:${RABBITMQ_PASSWORD:-perflab}" \
  http://127.0.0.1:15672/api/channels \
  > "${artifact_dir}/dependencies/rabbitmq-channels.json" || true

docker compose -f "${repo_root}/compose.yaml" ps --format json \
  | jq -s '.' \
  > "${artifact_dir}/dependencies/docker-compose-ps.json"

{
  dotnet --info
  docker version
  docker compose version
  wrk --version
  claude --version
} > "${artifact_dir}/source/tool-versions.txt" 2>&1 || true

if git -C "${repo_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "${repo_root}" status --short > "${artifact_dir}/source/git-status.txt"
  git -C "${repo_root}" diff --stat > "${artifact_dir}/source/git-diff-stat.txt"
fi

wrk_file="${artifact_dir}/benchmark/wrk.txt"
requests_per_second="$(awk '/Requests\/sec:/ {print $2}' "${wrk_file}" | tail -1)"
p50="$(awk '$1 == "50%" {print $2}' "${wrk_file}" | tail -1)"
p90="$(awk '$1 == "90%" {print $2}' "${wrk_file}" | tail -1)"
p99="$(awk '$1 == "99%" {print $2}' "${wrk_file}" | tail -1)"
non_2xx="$(awk '/Non-2xx or 3xx responses:/ {print $5}' "${wrk_file}" | tail -1)"
requests_per_second="${requests_per_second:-0}"
non_2xx="${non_2xx:-0}"

jq -n \
  --arg runId "${run_id}" \
  --arg telemetryRunId "${telemetry_run_id}" \
  --arg scenarioId "${scenario_id}" \
  --arg p50 "${p50:-unknown}" \
  --arg p90 "${p90:-unknown}" \
  --arg p99 "${p99:-unknown}" \
  --argjson requestsPerSecond "${requests_per_second}" \
  --argjson non2xx "${non_2xx}" \
  '{runId:$runId,telemetryRunId:$telemetryRunId,scenarioId:$scenarioId,observations:[{name:"http.requests_per_second",value:$requestsPerSecond,unit:"request/s",source:"benchmark/wrk.txt"},{name:"http.latency.p50",value:$p50,unit:"wrk-duration",source:"benchmark/wrk.txt"},{name:"http.latency.p90",value:$p90,unit:"wrk-duration",source:"benchmark/wrk.txt"},{name:"http.latency.p99",value:$p99,unit:"wrk-duration",source:"benchmark/wrk.txt"},{name:"http.responses.non_2xx_3xx",value:$non2xx,unit:"response",source:"benchmark/wrk.txt"}]}' \
  > "${artifact_dir}/facts.json"

temporary_manifest="${manifest}.tmp"
jq \
  --arg completedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson completedEpoch "${end_epoch}" \
  '. + {completedAt:$completedAt,completedEpoch:$completedEpoch,status:"captured"}' \
  "${manifest}" > "${temporary_manifest}"
mv "${temporary_manifest}" "${manifest}"
