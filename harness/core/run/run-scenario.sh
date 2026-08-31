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
# The measure phase can run longer than the requested duration (a soak stretches
# to >=600s, a spike adds fixed surge/recover segments). Use one effective
# duration for the manifest, the mid-load snapshot, and the fault window so they
# cannot diverge from what actually ran.
effective_duration="$(loadgen_effective_duration "${connections}" "${duration_seconds}")"
# Record fault parameters (set by run-fault.sh) so the package is self-describing.
fault_field=""
if [[ -n "${PERFLAB_FAULT_DEP:-}" ]]; then
  fault_field="$(printf ',"fault":{"dependency":"%s","kind":"%s","atSeconds":%s,"forSeconds":%s}' \
    "$(json_escape "${PERFLAB_FAULT_DEP}")" "$(json_escape "${PERFLAB_FAULT_KIND:-pause}")" \
    "${PERFLAB_FAULT_AT:-5}" "${PERFLAB_FAULT_FOR:-5}")"
fi
suite_field=""
if [[ -n "${suite_run_id}" ]]; then
  suite_field="$(printf ',"suite":{"runId":"%s","index":%s,"count":%s}' \
    "$(json_escape "${suite_run_id}")" "${suite_scenario_index}" "${suite_scenario_count}")"
fi
printf '{"runId":"%s","telemetryRunId":"%s","scenarioId":"%s","mode":"measure","workload":{"loadGenerator":"%s","baseUrl":"%s","method":"%s","path":"%s","durationSeconds":%s,"requestedDurationSeconds":%s,"connections":%s,"profile":"%s"},"startedAt":"%s","startedEpoch":%s,"source":{"gitRevision":"%s"}%s%s}\n' \
  "$(json_escape "${package_run_id}")" "$(json_escape "${telemetry_run_id}")" "$(json_escape "${scenario_id}")" \
  "$(json_escape "${load_generator}")" "$(json_escape "${base_url}")" "$(json_escape "${method}")" "$(json_escape "${path}")" \
  "${effective_duration}" "${duration_seconds}" "${connections}" "$(json_escape "${load_profile}")" "$(json_escape "${started_at}")" "${started_epoch}" \
  "$(json_escape "${git_revision}")" "${suite_field}" "${fault_field}" \
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

# Reset cumulative-since-reset dependency statistics (pg_stat_statements, redis
# stat counters/slowlog/latency) AFTER warm-up, so those snapshots reflect the
# MEASURE phase only. The range-gauge telemetry is already windowed to the measure
# phase, but these counters would otherwise accumulate from the pre-warm-up reset
# and fold ~10s of warm-up traffic into the evidence. Data/cache is left intact.
for dep in ${dependencies}; do
  reset_stats="$(dependency_dir "${dep}")/reset-stats.sh"
  if [[ -f "${reset_stats}" ]]; then
    bash "${reset_stats}" "${artifact_dir}" \
      || { echo "WARNING: ${dep} reset-stats failed; its cumulative counters still include warm-up." >&2; export PERFLAB_CAPTURE_INCOMPLETE=1; }
  fi
done

# Mid-load sampling: dependency live state at the halfway point, plus the app's
# own socket table and per-container resource use. This is BEST-EFFORT / OPTIONAL
# evidence -- a point-in-time peak snapshot whose signal is also covered by the
# windowed range-gauge telemetry (database_pool_metrics et al.). A failed mid-load
# capture is therefore WARNED about but deliberately NOT counted toward the package
# being partial (unlike the required post-run snapshot, which does).
sample_midload() {
  # Sample at the midpoint of the ACTUAL run (effective_duration), so a soak's
  # peak snapshot lands mid-soak rather than during VU warm-up.
  sleep $(( effective_duration / 2 ))
  for dep in ${dependencies}; do
    "$(dependency_dir "${dep}")/sample-midload.sh" "${artifact_dir}" \
      || echo "WARNING: ${dep} mid-load sample failed (best-effort peak snapshot; the windowed range-gauge telemetry still covers the peak)." >&2
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
  local inject_ok restore_ok
  if [[ "${kind}" == "stop" ]]; then
    compose stop "${dep}" >/dev/null 2>&1 && inject_ok=1 || inject_ok=0; sleep "${dur}"
    compose start "${dep}" >/dev/null 2>&1 && restore_ok=1 || restore_ok=0
  else
    compose pause "${dep}" >/dev/null 2>&1 && inject_ok=1 || inject_ok=0; sleep "${dur}"
    compose unpause "${dep}" >/dev/null 2>&1 && restore_ok=1 || restore_ok=0
  fi
  # A failed inject means the run measured a HEALTHY dependency -- say so loudly,
  # else the package looks like a resilience test that never actually happened.
  [[ "${inject_ok}" == "1" ]] || echo "[fault] WARNING: '${kind} ${dep}' did NOT take effect (compose returned non-zero); this run did not inject the fault." >&2
  # Report restore honestly; the EXIT/INT/TERM trap (restore_fault_dep) is the backstop.
  if [[ "${restore_ok}" == "1" ]]; then
    echo "[fault] ${dep} restored"
  else
    echo "[fault] WARNING: could not restore ${dep} inline; the cleanup trap will retry." >&2
  fi
  # Exit status encodes the outcome for the parent's `wait fault_pid`:
  #   0 = fault applied AND recovered within the measured window
  #   1 = fault did NOT apply (measured a healthy dependency)
  #   2 = applied but the inline restore failed (recovery was not observed in-window)
  if   [[ "${inject_ok}"  != "1" ]]; then return 1
  elif [[ "${restore_ok}" != "1" ]]; then return 2
  else return 0; fi
}

# Cleanup backstop: an interrupt (Ctrl-C) during the fault window kills the
# backgrounded inject_fault before it restores the dependency, leaving postgres
# paused/stopped -- and the next run wedges on it, since compose up won't unpause
# and stop_conflicting_lab_stacks skips the selected lab. This trap (armed only
# for a fault run) kills the injector and then best-effort restores on any exit;
# the restore is a no-op when the dependency is already running.
restore_fault_dep() {
  # Kill the background injector (and mid-load sampler) FIRST: on an early exit a
  # still-sleeping injector could otherwise wake and RE-APPLY the fault after we
  # have already restored the dependency.
  [[ -n "${fault_pid:-}" ]]   && { kill "${fault_pid}"   2>/dev/null || true; wait "${fault_pid}"   2>/dev/null || true; }
  [[ -n "${midload_pid:-}" ]] && { kill "${midload_pid}" 2>/dev/null || true; wait "${midload_pid}" 2>/dev/null || true; }
  [[ -n "${PERFLAB_FAULT_DEP:-}" ]] || return 0
  compose unpause "${PERFLAB_FAULT_DEP}" >/dev/null 2>&1 || true
  compose start "${PERFLAB_FAULT_DEP}" >/dev/null 2>&1 || true
}

echo "Measuring for ${effective_duration}s at ${connections} connections with ${load_generator}..."
# Arm the fault-cleanup trap only for a fault run, so a normal run adds no trap.
[[ -n "${PERFLAB_FAULT_DEP:-}" ]] && trap restore_fault_dep INT TERM EXIT
sample_midload & midload_pid=$!
inject_fault & fault_pid=$!
measure_started_epoch="$(date -u +%s)"
loadgen_measure "${artifact_dir}" measure
measure_ended_epoch="$(date -u +%s)"
wait "${midload_pid}" 2>/dev/null || true
fault_rc=0; wait "${fault_pid}" 2>/dev/null || fault_rc=$?
# Record whether the fault applied AND whether the dependency recovered within the
# measured window. Either failing makes the resilience package incomplete, so mark
# it partial rather than let a not-injected or not-recovered run read as a success.
if [[ -n "${PERFLAB_FAULT_DEP:-}" ]]; then
  case "${fault_rc}" in
    0) export PERFLAB_FAULT_APPLIED=true  PERFLAB_FAULT_RESTORED=true ;;
    2) export PERFLAB_FAULT_APPLIED=true  PERFLAB_FAULT_RESTORED=false PERFLAB_CAPTURE_INCOMPLETE=1 ;;
    *) export PERFLAB_FAULT_APPLIED=false PERFLAB_FAULT_RESTORED=false PERFLAB_CAPTURE_INCOMPLETE=1 ;;
  esac
fi

echo "Waiting 6 seconds for the final OTLP export batch..."
sleep 6
# Window telemetry/traces/logs/trends to the measured load only -- not Compose
# startup, the warm-up, or the post-load cooldown -- so range gauges (working set,
# heap) are not inflated into false "growth" and the trend/leak analysis reflects
# the measurement rather than process initialization.
export PERFLAB_MEASURE_START_EPOCH="${measure_started_epoch}" PERFLAB_MEASURE_END_EPOCH="${measure_ended_epoch}"
"${harness_core_dir}/capture/capture-evidence.sh" "${artifact_dir}"

# Resource-trend / leak detection on the captured range gauges (heap, working
# set, thread-pool queue, DB connections). This is the soak profile's payload --
# the growth signal a long run exists to surface -- but it is cheap and useful on
# any run (short windows self-mark as low-confidence).
"${harness_core_dir}/analyze/analyze-trends.sh" "${artifact_dir}" || true

echo "Evidence package: ${artifact_dir}"
echo "Next (optional runtime diagnostics): ${harness_core_dir}/capture/capture-runtime.sh ${artifact_dir}"
echo "Then analyze: ${harness_root}/ai/scripts/analyze-with-claude.sh ${artifact_dir}"
