#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_command curl
require_command jq

artifact_dir="${1:?Usage: capture-runtime.sh <artifact-directory> [trace|gcdump|stacks|dump] [duration-seconds]}"
manifest="${artifact_dir}/manifest.json"
scenario_id="$(jq -r '.scenarioId' "${manifest}")"
telemetry_run_id="$(jq -r '.telemetryRunId // .runId' "${manifest}")"

# The diagnostic workload defaults to whichever generator produced the
# measurement so the two runs stay comparable. An explicit environment value
# overrides it for a deliberate cross-generator comparison.
load_generator="${PERFLAB_LOAD_GENERATOR:-$(jq -r '.workload.loadGenerator // "wrk"' "${manifest}")}"
if [[ "${load_generator}" != "wrk" && "${load_generator}" != "k6" ]]; then
  echo "PERFLAB_LOAD_GENERATOR must be 'wrk' or 'k6'; received '${load_generator}'." >&2
  exit 1
fi
require_command "${load_generator}"
requested_kind="${2:-$(scenario_value "${scenario_id}" diagnostic)}"
kind="${requested_kind}"
fallback_reason=""
if [[ "${kind}" == "stacks" && "${PERFLAB_ENABLE_DOTNET_MONITOR_STACKS:-false}" != "true" ]]; then
  kind="trace"
  fallback_reason="dotnet-monitor /stacks is disabled by default because its in-process profiler channel is unreliable in this Docker Desktop sidecar topology"
  echo "Requested stacks for ${scenario_id}; capturing a CPU trace fallback instead."
  echo "Set PERFLAB_ENABLE_DOTNET_MONITOR_STACKS=true to explicitly retry /stacks."
fi
duration_seconds="${3:-30}"
target="$(scenario_value "${scenario_id}" target)"
assembly_name="PerfLab.Api"
if [[ "${target}" == "worker" ]]; then
  assembly_name="PerfLab.Worker"
fi

export PERF_SCENARIO="${scenario_id}"
export PERF_RUN_ID="${telemetry_run_id}"
export PERF_RUN_MODE="diagnose"
docker compose -f "${repo_root}/compose.yaml" up -d --force-recreate api worker
wait_for_api

processes_file="${artifact_dir}/runtime/processes-diagnostic.json"
mkdir -p "${artifact_dir}/runtime/${target}"
runtime_capture_file="${artifact_dir}/runtime/capture.json"
jq -n \
  --arg scenarioId "${scenario_id}" \
  --arg target "${target}" \
  --arg loadGenerator "${load_generator}" \
  --arg requestedDiagnostic "${requested_kind}" \
  --arg effectiveDiagnostic "${kind}" \
  --arg fallbackReason "${fallback_reason}" \
  --arg startedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson durationSeconds "${duration_seconds}" \
  '{scenarioId:$scenarioId,target:$target,loadGenerator:$loadGenerator,requestedDiagnostic:$requestedDiagnostic,effectiveDiagnostic:$effectiveDiagnostic,durationSeconds:$durationSeconds,startedAt:$startedAt,status:"running"}
  + if $fallbackReason == "" then {} else {fallbackReason:$fallbackReason} end' \
  > "${runtime_capture_file}"
curl -fsS http://127.0.0.1:52323/processes > "${processes_file}"
runtime_uid="$(jq -r --arg assembly "${assembly_name}" '.[] | select(((.managedEntryPointAssemblyName // "") | contains($assembly)) or ((.name // "") | contains($assembly))) | .uid' "${processes_file}" | head -1)"
if [[ -z "${runtime_uid}" || "${runtime_uid}" == "null" ]]; then
  echo "Could not find ${assembly_name} in dotnet-monitor /processes." >&2
  exit 1
fi

method="$(scenario_value "${scenario_id}" method)"
path="$(scenario_value "${scenario_id}" path)"
body="$(scenario_value "${scenario_id}" body)"
connections="$(scenario_value "${scenario_id}" connections)"
export PERF_METHOD="${method}"
export PERF_PATH="${path}"
export PERF_BODY="${body}"
# Pinned, not inherited: scripts/k6/scenario.js falls back to PERF_BASE_URL,
# so an ambient value in the caller's shell would benchmark a different
# target while health checks, telemetry, and profiling stay on this stack.
export PERF_BASE_URL="http://127.0.0.1:8080"

run_load() {
  if [[ "${load_generator}" == "wrk" ]]; then
    wrk -t4 -c"${connections}" -d"${duration_seconds}s" --latency \
      -s "${repo_root}/scripts/wrk/scenario.lua" \
      http://127.0.0.1:8080 \
      > "${artifact_dir}/benchmark/diagnostic-wrk.txt"
  else
    k6 run --vus "${connections}" --duration "${duration_seconds}s" \
      --summary-export "${artifact_dir}/benchmark/diagnostic-k6-summary.json" \
      --quiet --no-color \
      "${repo_root}/scripts/k6/scenario.js" \
      > "${artifact_dir}/benchmark/diagnostic-k6.txt"
  fi
}

case "${kind}" in
  trace)
    run_load &
    load_pid=$!
    curl -fsS --get \
      --data-urlencode "uid=${runtime_uid}" \
      --data-urlencode "durationSeconds=${duration_seconds}" \
      --data-urlencode "profile=cpu" \
      http://127.0.0.1:52323/trace \
      > "${artifact_dir}/runtime/${target}/cpu.nettrace"
    wait "${load_pid}"
    ;;
  gcdump)
    curl -fsS --get --data-urlencode "uid=${runtime_uid}" \
      http://127.0.0.1:52323/gcdump \
      > "${artifact_dir}/runtime/${target}/before.gcdump"
    run_load
    curl -fsS --get --data-urlencode "uid=${runtime_uid}" \
      http://127.0.0.1:52323/gcdump \
      > "${artifact_dir}/runtime/${target}/after.gcdump"
    ;;
  stacks)
    run_load &
    load_pid=$!
    sleep 5
    curl -fsS --get --data-urlencode "uid=${runtime_uid}" \
      http://127.0.0.1:52323/stacks \
      > "${artifact_dir}/runtime/${target}/stacks.json"
    wait "${load_pid}"
    ;;
  dump)
    run_load &
    load_pid=$!
    sleep 5
    curl -fsS --get \
      --data-urlencode "uid=${runtime_uid}" \
      --data-urlencode "type=Heap" \
      http://127.0.0.1:52323/dump \
      > "${artifact_dir}/runtime/${target}/process.dmp"
    wait "${load_pid}"
    ;;
  *)
    echo "Unknown diagnostic '${kind}'. Use trace, gcdump, stacks, or dump." >&2
    exit 1
    ;;
esac

temporary_capture="${runtime_capture_file}.tmp"
jq \
  --arg completedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '. + {completedAt:$completedAt,status:"captured"}' \
  "${runtime_capture_file}" > "${temporary_capture}"
mv "${temporary_capture}" "${runtime_capture_file}"

echo "Captured ${kind} for ${target}."
echo "Normalize it with: ${repo_root}/scripts/normalize-runtime.sh ${artifact_dir}"
