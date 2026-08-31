#!/usr/bin/env bash
# Measure one scenario and produce an evidence package. Runtime-agnostic: the
# app services, dependencies, load generator, and telemetry scoping all come
# from the descriptor and adapters via lib/common.sh.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

require_loadgen

scenario_id="${1:-S01}"
duration_seconds="${2:-30}"

if [[ -n "${PERF_MIX:-}" ]]; then
  # Mix run: the workload is a weighted request blend (PERF_MIX, set by
  # run-mix.sh), not a single catalog scenario. scenario_id is a free-form label
  # and the concurrency comes from PERFLAB_CONNECTIONS; the k6 workload reads
  # PERF_MIX and ignores PERF_METHOD/PATH/BODY.
  method="MIX"; path="(weighted mix)"; body=""
  connections="${PERFLAB_CONNECTIONS:?PERFLAB_CONNECTIONS is required for a PERF_MIX run}"
  # The app validates PERF_SCENARIO against its own catalog (and rejects a long
  # label), so a mix -- which is not a catalog scenario -- is tagged with the
  # lab's first scenario id for the APP, while the artifact dir and telemetry run
  # id keep the descriptive mix label.
  perf_scenario="$(scenario_ids_all | head -1)"
else
  require_scenario "${scenario_id}"
  method="$(scenario_value "${scenario_id}" method)"
  path="$(scenario_value "${scenario_id}" path)"
  body="$(scenario_value "${scenario_id}" body)"
  connections="$(scenario_value "${scenario_id}" connections)"
  perf_scenario="${scenario_id}"
fi
run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
scenario_lower="$(printf '%s' "${scenario_id}" | tr '[:upper:]' '[:lower:]')"
telemetry_run_id="${PERFLAB_TELEMETRY_RUN_ID:-${scenario_lower}-${run_stamp}}"
package_run_id="${PERFLAB_PACKAGE_RUN_ID:-${telemetry_run_id}}"
artifact_dir="${PERFLAB_ARTIFACT_DIR:-${artifacts_root}/runs/${package_run_id}}"
suite_run_id="${PERFLAB_SUITE_RUN_ID:-}"
suite_scenario_index="${PERFLAB_SUITE_SCENARIO_INDEX:-}"
suite_scenario_count="${PERFLAB_SUITE_SCENARIO_COUNT:-}"

mkdir -p "${artifact_dir}/benchmark" "${artifact_dir}/telemetry" \
         "${artifact_dir}/dependencies" "${artifact_dir}/runtime" "${artifact_dir}/analysis"

git_revision="unversioned"
if git -C "${repo_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_revision="$(git -C "${repo_root}" rev-parse HEAD)"
fi

# manifest.json is emitted with printf (no jq). The MSYS jq --arg path bug is
# gone because the path no longer passes through a native jq.exe.
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
started_epoch="$(date -u +%s)"
suite_field=""
if [[ -n "${suite_run_id}" ]]; then
  suite_field="$(printf ',"suite":{"runId":"%s","index":%s,"count":%s}' \
    "$(json_escape "${suite_run_id}")" "${suite_scenario_index}" "${suite_scenario_count}")"
fi
printf '{"runId":"%s","telemetryRunId":"%s","scenarioId":"%s","mode":"measure","workload":{"loadGenerator":"%s","baseUrl":"%s","method":"%s","path":"%s","durationSeconds":%s,"connections":%s,"profile":"%s"},"startedAt":"%s","startedEpoch":%s,"source":{"gitRevision":"%s"}%s}\n' \
  "$(json_escape "${package_run_id}")" "$(json_escape "${telemetry_run_id}")" "$(json_escape "${scenario_id}")" \
  "$(json_escape "${load_generator}")" "$(json_escape "${base_url}")" "$(json_escape "${method}")" "$(json_escape "${path}")" \
  "${duration_seconds}" "${connections}" "$(json_escape "${load_profile}")" "$(json_escape "${started_at}")" "${started_epoch}" \
  "$(json_escape "${git_revision}")" "${suite_field}" \
  > "${artifact_dir}/manifest.json"

export PERF_SCENARIO="${perf_scenario}" PERF_RUN_ID="${telemetry_run_id}" PERF_RUN_MODE="measure"
export PERF_METHOD="${method}" PERF_PATH="${path}" PERF_BODY="${body}" PERF_BASE_URL="${base_url}"
export PERFLAB_CONNECTIONS="${connections}" PERFLAB_DURATION_SECONDS="${duration_seconds}" PERFLAB_PROFILE="${load_profile}"

echo "Starting local stack for ${scenario_id} (${telemetry_run_id})..."
# Free the shared host ports first: other labs bind the same 8080/5432/etc.
stop_conflicting_lab_stacks
# shellcheck disable=SC2086
compose up -d --build ${app_services}
wait_for_api

# Dependency resets so the run is scenario-scoped.
for dep in ${dependencies}; do
  "$(dependency_dir "${dep}")/reset.sh" "${artifact_dir}"
done

echo "Warming up for 10 seconds with ${load_generator}..."
loadgen_warmup "${artifact_dir}"

# Mid-load sampling: dependency live state at the halfway point, plus the app's
# own socket table. Peak pool/connection usage is invisible once load stops.
sample_midload() {
  sleep $(( duration_seconds / 2 ))
  for dep in ${dependencies}; do
    "$(dependency_dir "${dep}")/sample-midload.sh" "${artifact_dir}" || true
  done
  compose exec -T "${primary_app_service}" sh -c 'cat /proc/net/tcp /proc/net/tcp6' \
    > "${artifact_dir}/dependencies/${primary_app_service}-net-tcp-midload.txt" 2>/dev/null || true
  # Per-container CPU/memory at peak load, scoped to this compose project. This is
  # the only host-side resource signal in the package: the runtime metrics show a
  # single .NET process, so a scenario whose latency grows while its process sits
  # below its own CPU quota can only be attributed to cross-container contention
  # (e.g. the co-located observability stack) with these numbers. NDJSON, one
  # container per line.
  local cids
  cids="$(compose ps -q 2>/dev/null | tr '\n' ' ')"
  if [[ -n "${cids// /}" ]]; then
    # shellcheck disable=SC2086
    MSYS_NO_PATHCONV=1 docker stats --no-stream --format '{{json .}}' ${cids} \
      > "${artifact_dir}/dependencies/container-stats-midload.ndjson" 2>/dev/null || true
  fi
}

# Optional fault injection during the measured window (PERFLAB_FAULT_DEP set by
# run-fault.sh): a dependency outage -- pause = a transient stall (connections
# hang), stop = a hard failure -- to measure resilience and whether the app
# recovers when the dependency returns. Docker-native, so no proxy or app change.
inject_fault() {
  [[ -n "${PERFLAB_FAULT_DEP:-}" ]] || return 0
  local dep="${PERFLAB_FAULT_DEP}" at="${PERFLAB_FAULT_AT:-5}" dur="${PERFLAB_FAULT_FOR:-5}" kind="${PERFLAB_FAULT_KIND:-pause}"
  sleep "${at}"
  echo "[fault] ${kind} ${dep} for ${dur}s (dependency-failure resilience test)"
  if [[ "${kind}" == "stop" ]]; then
    compose stop "${dep}" >/dev/null 2>&1 || true; sleep "${dur}"; compose start "${dep}" >/dev/null 2>&1 || true
  else
    compose pause "${dep}" >/dev/null 2>&1 || true; sleep "${dur}"; compose unpause "${dep}" >/dev/null 2>&1 || true
  fi
  echo "[fault] ${dep} restored"
}

echo "Measuring for ${duration_seconds}s at ${connections} connections with ${load_generator}..."
sample_midload & midload_pid=$!
inject_fault & fault_pid=$!
loadgen_measure "${artifact_dir}" measure
wait "${midload_pid}" 2>/dev/null || true
wait "${fault_pid}" 2>/dev/null || true

echo "Waiting 6 seconds for the final OTLP export batch..."
sleep 6
"${harness_core_dir}/capture/capture-evidence.sh" "${artifact_dir}"

# Resource-trend / leak detection on the captured range gauges (heap, working
# set, thread-pool queue, DB connections). This is the soak profile's payload --
# the growth signal a long run exists to surface -- but it is cheap and useful on
# any run (short windows self-mark as low-confidence).
"${harness_core_dir}/analyze/analyze-trends.sh" "${artifact_dir}" || true

echo "Evidence package: ${artifact_dir}"
echo "Next (optional runtime diagnostics): ${harness_core_dir}/capture/capture-runtime.sh ${artifact_dir}"
echo "Then analyze: ${harness_root}/ai/scripts/analyze-with-claude.sh ${artifact_dir}"
