#!/usr/bin/env bash
# Measure one scenario and produce an evidence package. Runtime-agnostic: the
# app services, dependencies, load generator, and telemetry scoping all come
# from the descriptor and adapters via lib/common.sh.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_loadgen

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
printf '{"runId":"%s","telemetryRunId":"%s","scenarioId":"%s","mode":"measure","workload":{"loadGenerator":"%s","baseUrl":"%s","method":"%s","path":"%s","durationSeconds":%s,"connections":%s},"startedAt":"%s","startedEpoch":%s,"source":{"gitRevision":"%s"}%s}\n' \
  "$(json_escape "${package_run_id}")" "$(json_escape "${telemetry_run_id}")" "$(json_escape "${scenario_id}")" \
  "$(json_escape "${load_generator}")" "$(json_escape "${base_url}")" "$(json_escape "${method}")" "$(json_escape "${path}")" \
  "${duration_seconds}" "${connections}" "$(json_escape "${started_at}")" "${started_epoch}" \
  "$(json_escape "${git_revision}")" "${suite_field}" \
  > "${artifact_dir}/manifest.json"

export PERF_SCENARIO="${scenario_id}" PERF_RUN_ID="${telemetry_run_id}" PERF_RUN_MODE="measure"
export PERF_METHOD="${method}" PERF_PATH="${path}" PERF_BODY="${body}" PERF_BASE_URL="${base_url}"
export PERFLAB_CONNECTIONS="${connections}" PERFLAB_DURATION_SECONDS="${duration_seconds}"

echo "Starting local stack for ${scenario_id} (${telemetry_run_id})..."
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
}

echo "Measuring for ${duration_seconds}s at ${connections} connections with ${load_generator}..."
sample_midload & midload_pid=$!
loadgen_measure "${artifact_dir}" measure
wait "${midload_pid}" 2>/dev/null || true

echo "Waiting 6 seconds for the final OTLP export batch..."
sleep 6
"${harness_core_dir}/capture-evidence.sh" "${artifact_dir}"

echo "Evidence package: ${artifact_dir}"
echo "Next (optional runtime diagnostics): ${harness_core_dir}/capture-runtime.sh ${artifact_dir}"
echo "Then analyze: ${harness_root}/ai/scripts/analyze-with-claude.sh ${artifact_dir}"
