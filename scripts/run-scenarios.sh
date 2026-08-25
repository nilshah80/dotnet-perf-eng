#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/run-scenarios.sh <S01,S07,...|all> [duration-seconds] [options]

Options:
  --with-runtime       Capture and normalize the recommended diagnostic. Managed stacks use a trace fallback by default.
  --continue-on-error  Continue with remaining scenarios if one scenario fails.
  -h, --help           Show this help.

Examples:
  ./scripts/run-scenarios.sh S01,S07,S12 30
  ./scripts/run-scenarios.sh all 30
  ./scripts/run-scenarios.sh all 30 --with-runtime
EOF
}

require_command jq

load_generator="${PERFLAB_LOAD_GENERATOR:-wrk}"
if [[ "${load_generator}" != "wrk" && "${load_generator}" != "k6" ]]; then
  echo "PERFLAB_LOAD_GENERATOR must be 'wrk' or 'k6'; received '${load_generator}'." >&2
  exit 1
fi
require_command "${load_generator}"

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 1
fi

if [[ "${1}" == "-h" || "${1}" == "--help" ]]; then
  usage
  exit 0
fi

selector="$1"
shift

duration_seconds="30"
if [[ $# -gt 0 && "${1}" != --* ]]; then
  duration_seconds="$1"
  shift
fi

if [[ ! "${duration_seconds}" =~ ^[1-9][0-9]*$ ]]; then
  echo "Duration must be a positive whole number of seconds; received '${duration_seconds}'." >&2
  exit 1
fi

with_runtime="false"
continue_on_error="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-runtime)
      with_runtime="true"
      ;;
    --continue-on-error)
      continue_on_error="true"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option '$1'." >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

normalized_selector="$(
  printf '%s' "${selector}" |
    tr '[:lower:]' '[:upper:]' |
    tr -d '[:space:]'
)"

if [[ -z "${normalized_selector}" ]]; then
  echo "At least one scenario must be selected." >&2
  exit 1
fi

scenario_ids=()
if [[ "${normalized_selector}" == "ALL" ]]; then
  while IFS= read -r scenario_id; do
    scenario_ids+=("${scenario_id}")
  done < <(jq -r 'keys[]' "${scenario_catalog}")
else
  if [[ "${normalized_selector}" == ,* || "${normalized_selector}" == *, || "${normalized_selector}" == *,,* ]]; then
    echo "Scenario selection contains an empty value: '${selector}'." >&2
    exit 1
  fi

  IFS=',' read -r -a requested_scenarios <<< "${normalized_selector}"
  for scenario_id in "${requested_scenarios[@]}"; do
    require_scenario "${scenario_id}"

    for existing_scenario_id in "${scenario_ids[@]:-}"; do
      if [[ "${existing_scenario_id}" == "${scenario_id}" ]]; then
        echo "Scenario '${scenario_id}' was selected more than once." >&2
        exit 1
      fi
    done

    scenario_ids+=("${scenario_id}")
  done
fi

scenario_count="${#scenario_ids[@]}"
if [[ "${scenario_count}" -eq 0 ]]; then
  echo "The scenario catalog did not contain any scenarios." >&2
  exit 1
fi

run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
suite_run_id="suite-${run_stamp}"
suite_dir="${repo_root}/artifacts/runs/${suite_run_id}"
collision_index=1
while [[ -e "${suite_dir}" ]]; do
  suite_run_id="suite-${run_stamp}-$(printf '%02d' "${collision_index}")"
  suite_dir="${repo_root}/artifacts/runs/${suite_run_id}"
  collision_index=$((collision_index + 1))
done

mkdir -p "${suite_dir}/scenarios"
suite_manifest="${suite_dir}/manifest.json"
suite_facts="${suite_dir}/facts.json"

git_revision="unversioned"
if git -C "${repo_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_revision="$(git -C "${repo_root}" rev-parse HEAD)"
fi

scenario_entries_json="$(
  scenario_index=0
  for scenario_id in "${scenario_ids[@]}"; do
    scenario_index=$((scenario_index + 1))
    scenario_lower="$(printf '%s' "${scenario_id}" | tr '[:upper:]' '[:lower:]')"
    telemetry_run_id="${suite_run_id}-${scenario_lower}"
    jq -n \
      --argjson index "${scenario_index}" \
      --arg scenarioId "${scenario_id}" \
      --arg name "$(scenario_value "${scenario_id}" name)" \
      --arg telemetryRunId "${telemetry_run_id}" \
      --arg artifactPath "scenarios/${scenario_id}" \
      --arg target "$(scenario_value "${scenario_id}" target)" \
      --arg diagnostic "$(scenario_value "${scenario_id}" diagnostic)" \
      '{index:$index,scenarioId:$scenarioId,name:$name,telemetryRunId:$telemetryRunId,artifactPath:$artifactPath,target:$target,diagnostic:$diagnostic,status:"pending"}'
  done | jq -s '.'
)"

jq -n \
  --arg runId "${suite_run_id}" \
  --arg kind "scenario-suite" \
  --arg selector "${selector}" \
  --arg status "running" \
  --arg startedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg gitRevision "${git_revision}" \
  --argjson startedEpoch "$(date -u +%s)" \
  --argjson durationSeconds "${duration_seconds}" \
  --arg loadGenerator "${load_generator}" \
  --argjson withRuntime "${with_runtime}" \
  --argjson scenarioCount "${scenario_count}" \
  --argjson scenarios "${scenario_entries_json}" \
  '{runId:$runId,kind:$kind,selector:$selector,status:$status,startedAt:$startedAt,startedEpoch:$startedEpoch,durationSeconds:$durationSeconds,loadGenerator:$loadGenerator,withRuntimeDiagnostics:$withRuntime,scenarioCount:$scenarioCount,completedCount:0,failedCount:0,source:{gitRevision:$gitRevision},scenarios:$scenarios}' \
  > "${suite_manifest}"

update_scenario_status() {
  local scenario_id="$1"
  local status="$2"
  local error_message="${3:-}"
  local temporary_manifest="${suite_manifest}.tmp"

  jq \
    --arg scenarioId "${scenario_id}" \
    --arg status "${status}" \
    --arg error "${error_message}" \
    --arg updatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.scenarios |= map(
      if .scenarioId == $scenarioId then
        . + {status:$status,updatedAt:$updatedAt}
        + if $error == "" then {} else {error:$error} end
      else . end
    )
    | .completedCount = ([.scenarios[] | select(.status == "completed")] | length)
    | .failedCount = ([.scenarios[] | select(.status == "failed")] | length)' \
    "${suite_manifest}" > "${temporary_manifest}"
  mv "${temporary_manifest}" "${suite_manifest}"
}

build_suite_facts() {
  local fact_files=()
  local scenario_id
  local scenario_dir

  for scenario_id in "${scenario_ids[@]}"; do
    scenario_dir="${suite_dir}/scenarios/${scenario_id}"
    if [[ -f "${scenario_dir}/facts.json" ]]; then
      fact_files+=("${scenario_dir}/facts.json")
    fi
  done

  if [[ "${#fact_files[@]}" -eq 0 ]]; then
    jq -n --arg runId "${suite_run_id}" \
      '{runId:$runId,kind:"scenario-suite",scenarioCount:0,scenarios:[]}' \
      > "${suite_facts}"
    return
  fi

  jq -s \
    --arg runId "${suite_run_id}" \
    '{runId:$runId,kind:"scenario-suite",scenarioCount:length,scenarios:map({scenarioId,telemetryRunId,loadGenerator,artifactPath:("scenarios/" + .scenarioId),observations})}' \
    "${fact_files[@]}" > "${suite_facts}"
}

finalize_suite() {
  local status="$1"
  local temporary_manifest="${suite_manifest}.tmp"

  build_suite_facts
  jq \
    --arg status "${status}" \
    --arg completedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson completedEpoch "$(date -u +%s)" \
    '. + {status:$status,completedAt:$completedAt,completedEpoch:$completedEpoch}' \
    "${suite_manifest}" > "${temporary_manifest}"
  mv "${temporary_manifest}" "${suite_manifest}"
}

active_scenario_id=""
handle_suite_signal() {
  local exit_code="$1"
  trap - INT TERM

  if [[ -n "${active_scenario_id}" ]]; then
    update_scenario_status "${active_scenario_id}" "interrupted" "Suite execution was interrupted." || true
  fi
  finalize_suite "interrupted" || true
  echo "Suite interrupted. Partial artifacts: ${suite_dir}" >&2
  exit "${exit_code}"
}

trap 'handle_suite_signal 130' INT
trap 'handle_suite_signal 143' TERM

completed_with_errors="false"
scenario_index=0

echo "Suite run ID: ${suite_run_id}"
echo "Load generator: ${load_generator}"
echo "Scenarios (${scenario_count}): ${scenario_ids[*]}"
echo "Suite artifacts: ${suite_dir}"

for scenario_id in "${scenario_ids[@]}"; do
  scenario_index=$((scenario_index + 1))
  scenario_lower="$(printf '%s' "${scenario_id}" | tr '[:upper:]' '[:lower:]')"
  scenario_dir="${suite_dir}/scenarios/${scenario_id}"
  telemetry_run_id="${suite_run_id}-${scenario_lower}"

  echo
  echo "[${scenario_index}/${scenario_count}] Measuring ${scenario_id}..."
  active_scenario_id="${scenario_id}"
  update_scenario_status "${scenario_id}" "running"

  scenario_exit=0
  PERFLAB_SUITE_RUN_ID="${suite_run_id}" \
  PERFLAB_SUITE_SCENARIO_INDEX="${scenario_index}" \
  PERFLAB_SUITE_SCENARIO_COUNT="${scenario_count}" \
  PERFLAB_PACKAGE_RUN_ID="${suite_run_id}" \
  PERFLAB_TELEMETRY_RUN_ID="${telemetry_run_id}" \
  PERFLAB_ARTIFACT_DIR="${scenario_dir}" \
    "${repo_root}/scripts/run-scenario.sh" "${scenario_id}" "${duration_seconds}" || scenario_exit=$?

  if [[ "${scenario_exit}" -eq 0 && "${with_runtime}" == "true" ]]; then
    diagnostic="$(scenario_value "${scenario_id}" diagnostic)"
    echo "[${scenario_index}/${scenario_count}] Capturing ${diagnostic} for ${scenario_id}..."
    "${repo_root}/scripts/capture-runtime.sh" "${scenario_dir}" "${diagnostic}" "${duration_seconds}" || scenario_exit=$?

    if [[ "${scenario_exit}" -eq 0 ]]; then
      "${repo_root}/scripts/normalize-runtime.sh" "${scenario_dir}" || scenario_exit=$?
    fi
  fi

  if [[ "${scenario_exit}" -eq 0 ]]; then
    update_scenario_status "${scenario_id}" "completed"
    active_scenario_id=""
    echo "[${scenario_index}/${scenario_count}] Completed ${scenario_id}: ${scenario_dir}"
    continue
  fi

  completed_with_errors="true"
  update_scenario_status "${scenario_id}" "failed" "Scenario command exited with status ${scenario_exit}."
  active_scenario_id=""
  echo "[${scenario_index}/${scenario_count}] ${scenario_id} failed with status ${scenario_exit}." >&2

  if [[ "${continue_on_error}" != "true" ]]; then
    finalize_suite "failed"
    echo "Suite stopped after ${scenario_id}. Partial artifacts: ${suite_dir}" >&2
    exit "${scenario_exit}"
  fi
done

if [[ "${completed_with_errors}" == "true" ]]; then
  finalize_suite "completed-with-errors"
  suite_exit=1
else
  finalize_suite "completed"
  suite_exit=0
fi

echo
echo "Suite completed with status: $(jq -r '.status' "${suite_manifest}")"
echo "Suite run ID: ${suite_run_id}"
echo "Suite artifacts: ${suite_dir}"
echo "Aggregate facts: ${suite_facts}"
exit "${suite_exit}"
