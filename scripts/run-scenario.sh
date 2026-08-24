#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_command docker
require_command curl
require_command jq

# wrk stays the default load generator. k6 is opt-in, and the two are not
# numerically comparable to each other, so the generator is recorded in the
# manifest and must be held constant across a before/after comparison.
load_generator="${PERFLAB_LOAD_GENERATOR:-wrk}"
if [[ "${load_generator}" != "wrk" && "${load_generator}" != "k6" ]]; then
  echo "PERFLAB_LOAD_GENERATOR must be 'wrk' or 'k6'; received '${load_generator}'." >&2
  exit 1
fi
require_command "${load_generator}"

scenario_id="${1:-S01}"
duration_seconds="${2:-30}"
require_scenario "${scenario_id}"

method="$(scenario_value "${scenario_id}" method)"
path="$(scenario_value "${scenario_id}" path)"
body="$(scenario_value "${scenario_id}" body)"
connections="$(scenario_value "${scenario_id}" connections)"
run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
scenario_lower="$(printf '%s' "${scenario_id}" | tr '[:upper:]' '[:lower:]')"
telemetry_run_id="${PERFLAB_TELEMETRY_RUN_ID:-${scenario_lower}-${run_stamp}}"
package_run_id="${PERFLAB_PACKAGE_RUN_ID:-${telemetry_run_id}}"
artifact_dir="${PERFLAB_ARTIFACT_DIR:-${repo_root}/artifacts/runs/${package_run_id}}"
suite_run_id="${PERFLAB_SUITE_RUN_ID:-}"
suite_scenario_index="${PERFLAB_SUITE_SCENARIO_INDEX:-}"
suite_scenario_count="${PERFLAB_SUITE_SCENARIO_COUNT:-}"

mkdir -p "${artifact_dir}/benchmark" "${artifact_dir}/telemetry" "${artifact_dir}/dependencies" "${artifact_dir}/runtime" "${artifact_dir}/analysis"

git_revision="unversioned"
if git -C "${repo_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_revision="$(git -C "${repo_root}" rev-parse HEAD)"
fi

jq -n \
  --arg runId "${package_run_id}" \
  --arg telemetryRunId "${telemetry_run_id}" \
  --arg scenarioId "${scenario_id}" \
  --arg suiteRunId "${suite_run_id}" \
  --arg suiteScenarioIndex "${suite_scenario_index}" \
  --arg suiteScenarioCount "${suite_scenario_count}" \
  --arg mode "measure" \
  --arg loadGenerator "${load_generator}" \
  --arg baseUrl "http://127.0.0.1:8080" \
  --arg method "${method}" \
  --arg path "${path}" \
  --arg startedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg gitRevision "${git_revision}" \
  --argjson startedEpoch "$(date -u +%s)" \
  --argjson durationSeconds "${duration_seconds}" \
  --argjson connections "${connections}" \
  '{runId:$runId,telemetryRunId:$telemetryRunId,scenarioId:$scenarioId,mode:$mode,workload:{loadGenerator:$loadGenerator,baseUrl:$baseUrl,method:$method,path:$path,durationSeconds:$durationSeconds,connections:$connections},startedAt:$startedAt,startedEpoch:$startedEpoch,source:{gitRevision:$gitRevision}}
  + if $suiteRunId == "" then {}
    else {suite:{runId:$suiteRunId,index:($suiteScenarioIndex | tonumber),count:($suiteScenarioCount | tonumber)}}
    end' \
  > "${artifact_dir}/manifest.json"

export PERF_SCENARIO="${scenario_id}"
export PERF_RUN_ID="${telemetry_run_id}"
export PERF_RUN_MODE="measure"

echo "Starting local stack for ${scenario_id} (${telemetry_run_id})..."
docker compose -f "${repo_root}/compose.yaml" up -d --build api worker
wait_for_api

docker compose -f "${repo_root}/compose.yaml" exec -T redis redis-cli FLUSHALL >/dev/null
# FLUSHALL clears keys but not INFO counters, so keyspace_hits/misses stayed
# cumulative for the container's lifetime and had to be read as deltas between
# consecutive scenarios. Resetting makes redis-info.txt scenario-scoped.
docker compose -f "${repo_root}/compose.yaml" exec -T redis redis-cli CONFIG RESETSTAT >/dev/null
docker compose -f "${repo_root}/compose.yaml" exec -T postgres \
  psql -U perflab -d perflab -c "SELECT pg_stat_statements_reset();" >/dev/null
docker compose -f "${repo_root}/compose.yaml" exec -T rabbitmq \
  rabbitmqctl purge_queue perf.orders.created >/dev/null 2>&1 || true
docker compose -f "${repo_root}/compose.yaml" exec -T rabbitmq \
  rabbitmqctl purge_queue perf.orders.dead >/dev/null 2>&1 || true

# Baseline for the broker's cumulative opened/closed counters, taken after the
# dependency reset and before any load, so churn during the run is a difference
# rather than an absolute that carries every earlier scenario's history.
curl -fsS --max-time 15 http://127.0.0.1:15692/metrics 2>/dev/null \
  | grep -E '^rabbitmq_(connections|channels)' \
  > "${artifact_dir}/dependencies/rabbitmq-broker-metrics-preload.txt" || true

export PERF_METHOD="${method}"
export PERF_PATH="${path}"
export PERF_BODY="${body}"
# Pinned, not inherited: scripts/k6/scenario.js falls back to PERF_BASE_URL,
# so an ambient value in the caller's shell would benchmark a different
# target while health checks, telemetry, and profiling stay on this stack.
export PERF_BASE_URL="http://127.0.0.1:8080"

echo "Warming up for 10 seconds with ${load_generator}..."
if [[ "${load_generator}" == "wrk" ]]; then
  wrk -t2 -c16 -d10s \
    -s "${repo_root}/scripts/wrk/scenario.lua" \
    http://127.0.0.1:8080 \
    > "${artifact_dir}/benchmark/warmup.txt"
else
  k6 run --vus 16 --duration 10s \
    --summary-export "${artifact_dir}/benchmark/k6-warmup.json" \
    --quiet --no-color \
    "${repo_root}/scripts/k6/scenario.js" \
    > "${artifact_dir}/benchmark/k6-warmup.txt"
fi

# Every dependency snapshot used to be taken after the load stopped, which made
# peak pool usage and connection churn invisible: a scenario that creates a
# connection per request showed a fully idle broker by capture time. This samples
# the live state once, halfway through the measurement.
sample_midload() {
  local out="${artifact_dir}/dependencies"
  sleep $(( duration_seconds / 2 ))
  docker compose -f "${repo_root}/compose.yaml" exec -T postgres \
    psql -U perflab -d perflab -c \
    "COPY (SELECT application_name, state, count(*) AS connections FROM pg_stat_activity WHERE datname='perflab' GROUP BY application_name, state ORDER BY application_name, state) TO STDOUT WITH CSV HEADER" \
    > "${out}/postgres-connections-midload.csv" 2>/dev/null || true
  docker compose -f "${repo_root}/compose.yaml" exec -T redis redis-cli INFO clients \
    > "${out}/redis-clients-midload.txt" 2>/dev/null || true
  curl -fsS --max-time 10 -u "perflab:${RABBITMQ_PASSWORD:-perflab}" \
    http://127.0.0.1:15672/api/connections > "${out}/rabbitmq-connections-midload.json" 2>/dev/null || true
  curl -fsS --max-time 10 -u "perflab:${RABBITMQ_PASSWORD:-perflab}" \
    http://127.0.0.1:15672/api/channels > "${out}/rabbitmq-channels-midload.json" 2>/dev/null || true
  docker compose -f "${repo_root}/compose.yaml" exec -T api \
    sh -c 'cat /proc/net/tcp /proc/net/tcp6' > "${out}/api-net-tcp-midload.txt" 2>/dev/null || true
}

echo "Measuring for ${duration_seconds} seconds at ${connections} connections with ${load_generator}..."
sample_midload &
midload_pid=$!
if [[ "${load_generator}" == "wrk" ]]; then
  wrk -t4 -c"${connections}" -d"${duration_seconds}s" --latency \
    -s "${repo_root}/scripts/wrk/scenario.lua" \
    http://127.0.0.1:8080 \
    > "${artifact_dir}/benchmark/wrk.txt"
else
  k6 run --vus "${connections}" --duration "${duration_seconds}s" \
    --summary-export "${artifact_dir}/benchmark/k6-summary.json" \
    --quiet --no-color \
    "${repo_root}/scripts/k6/scenario.js" \
    > "${artifact_dir}/benchmark/k6.txt"
fi

wait "${midload_pid}" 2>/dev/null || true

echo "Waiting 6 seconds for the final OTLP export batch..."
sleep 6
"${repo_root}/scripts/capture-evidence.sh" "${artifact_dir}"

echo "Evidence package: ${artifact_dir}"
echo "Next: ${repo_root}/scripts/capture-runtime.sh ${artifact_dir}"
echo "Then: ${repo_root}/scripts/analyze-with-claude.sh ${artifact_dir}"
