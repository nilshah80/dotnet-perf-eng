#!/usr/bin/env bash
# Capture in-process runtime diagnostics in a SEPARATE diagnose-mode run (kept
# apart from measurement because profiling perturbs the process). Runtime-
# specific capture is delegated to the runtime adapter's capture.sh.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

artifact_dir="${1:?Usage: capture-runtime.sh <artifact-directory> [trace|gcdump|stacks|dump] [duration-seconds]}"
manifest="${artifact_dir}/manifest.json"
[[ -f "${manifest}" ]] || { echo "Manifest not found: ${manifest}" >&2; exit 1; }

IFS=$'\t' read -r scenario_id telemetry_run_id manifest_generator < <(
  jqd -r '[.scenarioId,(.telemetryRunId//.runId),(.workload.loadGenerator//"wrk")] | @tsv' < "${manifest}")

# Default the diagnostic load to the measurement's generator so the two runs
# stay comparable; an explicit env override wins.
load_generator="${PERFLAB_LOAD_GENERATOR:-${manifest_generator}}"
if [[ "${load_generator}" != "wrk" && "${load_generator}" != "k6" ]]; then
  echo "PERFLAB_LOAD_GENERATOR must be 'wrk' or 'k6'; received '${load_generator}'." >&2
  exit 1
fi
require_loadgen
export PERFLAB_LOAD_GENERATOR="${load_generator}"

requested_kind="${2:-$(scenario_value "${scenario_id}" diagnostic)}"
duration_seconds="${3:-30}"
target="$(scenario_value "${scenario_id}" target)"

export PERF_SCENARIO="${scenario_id}" PERF_RUN_ID="${telemetry_run_id}" PERF_RUN_MODE="diagnose"
export PERF_METHOD="$(scenario_value "${scenario_id}" method)"
export PERF_PATH="$(scenario_value "${scenario_id}" path)"
export PERF_BODY="$(scenario_value "${scenario_id}" body)"
export PERF_BASE_URL="${base_url}"
export PERFLAB_CONNECTIONS="$(scenario_value "${scenario_id}" connections)"
export PERFLAB_DURATION_SECONDS="${duration_seconds}"

echo "Recreating app in diagnose mode for ${scenario_id}..."
# shellcheck disable=SC2086
compose up -d --force-recreate ${app_services}
wait_for_api

capture="${runtime_adapter_dir}/capture.sh"
if [[ ! -f "${capture}" ]]; then
  echo "Runtime adapter '${runtime}' has no capture.sh at ${capture}." >&2
  exit 1
fi
"${capture}" "${artifact_dir}" "${requested_kind}" "${duration_seconds}" "${target}"

echo "Normalize it with: ${harness_core_dir}/normalize-runtime.sh ${artifact_dir}"
