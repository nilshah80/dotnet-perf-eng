#!/usr/bin/env bash
# Suite orchestrator: run selected scenarios sequentially under one suite run id.
# Suite state lives in bash arrays and the manifest is emitted with printf (no
# jq); only the final cross-scenario facts aggregation uses dockerized jq (jqd).
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_loadgen

usage() {
  cat <<'EOF'
Usage:
  ./harness/core/run-scenarios.sh <S01,S07,...|all> [duration-seconds] [options]

Options:
  --with-runtime       Capture and normalize the recommended diagnostic (DEFAULT ON).
                       Managed stacks use a trace fallback by default.
  --no-runtime         Measurement only -- skip runtime capture. Use this for a
    (--measure-only)   clean, un-perturbed latency/throughput baseline, since
                       profiling roughly doubles wall-clock and perturbs the process.
  --continue-on-error  Continue with remaining scenarios if one scenario fails.
  -h, --help           Show this help.

Examples:
  ./harness/core/run-scenarios.sh S01,S07,S12 30              # with runtime diagnostics
  ./harness/core/run-scenarios.sh S01,S07,S12 30 --no-runtime # clean measurement only
  ./harness/core/run-scenarios.sh all 30 --continue-on-error
EOF
}

[[ $# -eq 0 ]] && { usage >&2; exit 1; }
[[ "${1}" == "-h" || "${1}" == "--help" ]] && { usage; exit 0; }

selector="$1"; shift
duration_seconds="30"
if [[ $# -gt 0 && "${1}" != --* ]]; then duration_seconds="$1"; shift; fi
[[ "${duration_seconds}" =~ ^[1-9][0-9]*$ ]] || { echo "Duration must be a positive whole number of seconds; received '${duration_seconds}'." >&2; exit 1; }

# Runtime diagnostics are ON by default; --no-runtime opts out for a clean,
# un-perturbed measurement baseline (profiling ~doubles wall-clock and perturbs
# the process, so measure-only runs are still the right choice for A/B latency).
with_runtime="true"; continue_on_error="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-runtime) with_runtime="true" ;;
    --no-runtime|--measure-only) with_runtime="false" ;;
    --continue-on-error) continue_on_error="true" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option '$1'." >&2; usage >&2; exit 1 ;;
  esac
  shift
done

normalized_selector="$(printf '%s' "${selector}" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')"
[[ -n "${normalized_selector}" ]] || { echo "At least one scenario must be selected." >&2; exit 1; }

scenario_ids=()
if [[ "${normalized_selector}" == "ALL" ]]; then
  while IFS= read -r sid; do scenario_ids+=("${sid}"); done < <(scenario_ids_all)
else
  if [[ "${normalized_selector}" == ,* || "${normalized_selector}" == *, || "${normalized_selector}" == *,,* ]]; then
    echo "Scenario selection contains an empty value: '${selector}'." >&2; exit 1
  fi
  IFS=',' read -r -a requested <<< "${normalized_selector}"
  for sid in "${requested[@]}"; do
    require_scenario "${sid}"
    for existing in "${scenario_ids[@]:-}"; do
      [[ "${existing}" == "${sid}" ]] && { echo "Scenario '${sid}' was selected more than once." >&2; exit 1; }
    done
    scenario_ids+=("${sid}")
  done
fi
scenario_count="${#scenario_ids[@]}"
[[ "${scenario_count}" -gt 0 ]] || { echo "No scenarios selected." >&2; exit 1; }

run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
suite_run_id="suite-${run_stamp}"
suite_dir="${artifacts_root}/runs/${suite_run_id}"
ci=1
while [[ -e "${suite_dir}" ]]; do
  suite_run_id="suite-${run_stamp}-$(printf '%02d' "${ci}")"
  suite_dir="${artifacts_root}/runs/${suite_run_id}"
  ci=$((ci + 1))
done
mkdir -p "${suite_dir}/scenarios"
suite_manifest="${suite_dir}/manifest.json"
suite_facts="${suite_dir}/facts.json"

git_revision="unversioned"
if git -C "${repo_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_revision="$(git -C "${repo_root}" rev-parse HEAD)"
fi

declare -a s_id s_name s_telemetry s_target s_diag s_status s_updated s_error
for ((i = 0; i < scenario_count; i++)); do
  sid="${scenario_ids[i]}"
  s_id[i]="${sid}"
  s_name[i]="$(scenario_value "${sid}" name)"
  s_telemetry[i]="${suite_run_id}-$(printf '%s' "${sid}" | tr '[:upper:]' '[:lower:]')"
  s_target[i]="$(scenario_value "${sid}" target)"
  s_diag[i]="$(scenario_value "${sid}" diagnostic)"
  s_status[i]="pending"; s_updated[i]=""; s_error[i]=""
done

suite_status="running"; completed_at=""; completed_epoch=""
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; started_epoch="$(date -u +%s)"

write_suite_manifest() {
  local tmp="${suite_manifest}.tmp" i completed=0 failed=0
  for ((i = 0; i < scenario_count; i++)); do
    [[ "${s_status[i]}" == "completed" ]] && completed=$((completed + 1))
    [[ "${s_status[i]}" == "failed" ]] && failed=$((failed + 1))
  done
  {
    printf '{"runId":"%s","kind":"scenario-suite","selector":"%s","status":"%s","startedAt":"%s","startedEpoch":%s,"durationSeconds":%s,"loadGenerator":"%s","withRuntimeDiagnostics":%s,"scenarioCount":%s,"completedCount":%s,"failedCount":%s,"source":{"gitRevision":"%s"}' \
      "$(json_escape "${suite_run_id}")" "$(json_escape "${selector}")" "$(json_escape "${suite_status}")" \
      "$(json_escape "${started_at}")" "${started_epoch}" "${duration_seconds}" "$(json_escape "${load_generator}")" \
      "${with_runtime}" "${scenario_count}" "${completed}" "${failed}" "$(json_escape "${git_revision}")"
    [[ -n "${completed_at}" ]] && printf ',"completedAt":"%s","completedEpoch":%s' "$(json_escape "${completed_at}")" "${completed_epoch}"
    printf ',"scenarios":['
    for ((i = 0; i < scenario_count; i++)); do
      [[ $i -gt 0 ]] && printf ','
      printf '{"index":%s,"scenarioId":"%s","name":"%s","telemetryRunId":"%s","artifactPath":"scenarios/%s","target":"%s","diagnostic":"%s","status":"%s"' \
        "$((i + 1))" "$(json_escape "${s_id[i]}")" "$(json_escape "${s_name[i]}")" "$(json_escape "${s_telemetry[i]}")" \
        "$(json_escape "${s_id[i]}")" "$(json_escape "${s_target[i]}")" "$(json_escape "${s_diag[i]}")" "$(json_escape "${s_status[i]}")"
      [[ -n "${s_updated[i]}" ]] && printf ',"updatedAt":"%s"' "$(json_escape "${s_updated[i]}")"
      [[ -n "${s_error[i]}" ]] && printf ',"error":"%s"' "$(json_escape "${s_error[i]}")"
      printf '}'
    done
    printf ']}\n'
  } > "${tmp}"
  mv "${tmp}" "${suite_manifest}"
}

set_status() {
  local i="$1" status="$2" error="${3:-}"
  s_status[i]="${status}"; s_updated[i]="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; s_error[i]="${error}"
  write_suite_manifest
}

build_suite_facts() {
  local i meta files=()
  # HTTP error-rate above which a scenario is flagged health:"degraded" in the
  # index (env-overridable). A scenario can be pipeline-"completed" yet have most
  # requests fail -- e.g. a saturated connection pool returning timeouts -- which
  # the raw status hides; health surfaces that without conflating it with a
  # harness/pipeline failure.
  local health_threshold="${PERFLAB_MAX_HTTP_ERROR_RATE:-0.05}"
  [[ "${health_threshold}" =~ ^[0-9]*\.?[0-9]+$ ]] || health_threshold="0.05"
  # Build the scenario list from the suite's OWN arrays so the terminal status is
  # authoritative. facts.json is CLAUDE.md's index, but it was previously
  # assembled purely from the per-scenario facts.json files -- which are written
  # at measurement time and mention neither status nor health. A scenario that
  # failed LATER (e.g. a --with-runtime normalize failure) or that ran green while
  # most requests errored then read as a clean run. Carry status/error/health
  # here, and list every selected scenario (observations:null when it emitted no
  # facts).
  meta='['
  for ((i = 0; i < scenario_count; i++)); do
    [[ $i -gt 0 ]] && meta+=','
    meta+=$(printf '{"scenarioId":"%s","telemetryRunId":"%s","loadGenerator":"%s","artifactPath":"scenarios/%s","status":"%s"' \
      "$(json_escape "${s_id[i]}")" "$(json_escape "${s_telemetry[i]}")" "$(json_escape "${load_generator}")" \
      "$(json_escape "${s_id[i]}")" "$(json_escape "${s_status[i]}")")
    [[ -n "${s_error[i]}" ]] && meta+=$(printf ',"error":"%s"' "$(json_escape "${s_error[i]}")")
    meta+='}'
    [[ -f "${suite_dir}/scenarios/${s_id[i]}/facts.json" ]] && files+=("${suite_dir}/scenarios/${s_id[i]}/facts.json")
  done
  meta+=']'
  if [[ "${#files[@]}" -eq 0 ]]; then
    printf '%s' "${meta}" | jqd --arg runId "${suite_run_id}" \
      '{runId:$runId,kind:"scenario-suite",scenarioCount:length,scenarios:map(. + {observations:null,errorRate:null,health:"unknown"})}' > "${suite_facts}"
    return
  fi
  cat "${files[@]}" | jqd -s --arg runId "${suite_run_id}" --argjson meta "${meta}" --argjson threshold "${health_threshold}" \
    '(reduce .[] as $f ({}; . + {($f.scenarioId): $f.observations})) as $obs
     | def errRate($o): (($o // []) as $x
         | ((($x|map(select(.name=="http.responses.non_2xx_3xx"))|.[0].value) // 0)
            + (($x|map(select(.name=="http.transport_errors"))|.[0].value) // 0)) as $err
         | (($x|map(select(.name=="http.requests.total"))|.[0].value) // 0) as $tot
         | if $tot > 0 then ($err / $tot) else 0 end);
       {runId:$runId,kind:"scenario-suite",scenarioCount:($meta|length),
        scenarios:($meta|map(
          ($obs[.scenarioId] // null) as $o
          | . + {observations:$o,
                 errorRate:(if $o == null then null else (errRate($o)*10000|round/10000) end),
                 health:(if $o == null then "unknown" elif errRate($o) > $threshold then "degraded" else "ok" end)}))}' \
    > "${suite_facts}"
}

finalize_suite() {
  suite_status="$1"
  completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; completed_epoch="$(date -u +%s)"
  build_suite_facts
  write_suite_manifest
}

active_index=-1
handle_signal() {
  local code="$1"; trap - INT TERM
  if [[ "${active_index}" -ge 0 ]]; then
    s_status[active_index]="interrupted"; s_updated[active_index]="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    s_error[active_index]="Suite execution was interrupted."
  fi
  finalize_suite "interrupted" || true
  echo "Suite interrupted. Partial artifacts: ${suite_dir}" >&2
  exit "${code}"
}
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

write_suite_manifest

echo "Suite run ID: ${suite_run_id}"
echo "Load generator: ${load_generator}"
echo "Scenarios (${scenario_count}): ${scenario_ids[*]}"
echo "Suite artifacts: ${suite_dir}"

completed_with_errors="false"
for ((i = 0; i < scenario_count; i++)); do
  sid="${s_id[i]}"
  scenario_dir="${suite_dir}/scenarios/${sid}"
  echo; echo "[$((i + 1))/${scenario_count}] Measuring ${sid}..."
  active_index="${i}"
  set_status "${i}" "running"

  scenario_exit=0
  PERFLAB_SUITE_RUN_ID="${suite_run_id}" \
  PERFLAB_SUITE_SCENARIO_INDEX="$((i + 1))" \
  PERFLAB_SUITE_SCENARIO_COUNT="${scenario_count}" \
  PERFLAB_PACKAGE_RUN_ID="${suite_run_id}" \
  PERFLAB_TELEMETRY_RUN_ID="${s_telemetry[i]}" \
  PERFLAB_ARTIFACT_DIR="${scenario_dir}" \
    "${harness_core_dir}/run-scenario.sh" "${sid}" "${duration_seconds}" || scenario_exit=$?

  if [[ "${scenario_exit}" -eq 0 && "${with_runtime}" == "true" ]]; then
    echo "[$((i + 1))/${scenario_count}] Capturing ${s_diag[i]} for ${sid}..."
    "${harness_core_dir}/capture-runtime.sh" "${scenario_dir}" "${s_diag[i]}" "${duration_seconds}" || scenario_exit=$?
    [[ "${scenario_exit}" -eq 0 ]] && { "${harness_core_dir}/normalize-runtime.sh" "${scenario_dir}" || scenario_exit=$?; }
  fi

  if [[ "${scenario_exit}" -eq 0 ]]; then
    set_status "${i}" "completed"; active_index=-1
    echo "[$((i + 1))/${scenario_count}] Completed ${sid}: ${scenario_dir}"
    continue
  fi

  completed_with_errors="true"
  set_status "${i}" "failed" "Scenario command exited with status ${scenario_exit}."
  active_index=-1
  echo "[$((i + 1))/${scenario_count}] ${sid} failed with status ${scenario_exit}." >&2
  if [[ "${continue_on_error}" != "true" ]]; then
    finalize_suite "failed"
    echo "Suite stopped after ${sid}. Partial artifacts: ${suite_dir}" >&2
    exit "${scenario_exit}"
  fi
done

if [[ "${completed_with_errors}" == "true" ]]; then
  finalize_suite "completed-with-errors"; suite_exit=1
else
  finalize_suite "completed"; suite_exit=0
fi

echo
echo "Suite completed with status: ${suite_status}"
echo "Suite run ID: ${suite_run_id}"
echo "Suite artifacts: ${suite_dir}"
echo "Aggregate facts: ${suite_facts}"
exit "${suite_exit}"
