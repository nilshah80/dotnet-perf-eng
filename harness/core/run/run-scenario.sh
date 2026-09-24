#!/usr/bin/env bash
# Measure one scenario and produce an evidence package. Runtime-agnostic: the
# app services, dependencies, load generator, and telemetry scoping all come
# from the descriptor and adapters via lib/common.sh.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"
# shellcheck disable=SC1091
source "${harness_core_dir}/lib/performance.sh"

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
  export PERF_WORKLOAD_KIND="mix"
  # The app validates PERF_SCENARIO against its own catalog (and rejects a long
  # label), so a mix -- which is not a catalog scenario -- is tagged with the
  # lab's first scenario id for the APP, while the artifact dir and telemetry run
  # id keep the descriptive mix label.
  perf_scenario="$(scenario_ids_all | head -1)"
else
  require_scenario "${scenario_id}"
  export PERF_WORKLOAD_KIND="$(scenario_value "${scenario_id}" type)"
  export PERF_PROTOCOL="$(scenario_value "${scenario_id}" selector || true)"
  if [[ "${PERF_WORKLOAD_KIND}" == "journey" ]]; then
    # Journeys are declared in catalog.json and implemented by the project-owned
    # load script. They intentionally have no single HTTP method/path/body.
    method="JOURNEY"
    path="${PERF_PROTOCOL}"
    body=""
  else
    method="$(scenario_value "${scenario_id}" method)"
    path="$(scenario_value "${scenario_id}" path)"
    body="$(scenario_value "${scenario_id}" body)"
  fi
  connections="$(scenario_value "${scenario_id}" connections)"
  perf_scenario="${scenario_id}"
  if [[ "${PERF_WORKLOAD_KIND}" == "journey" ]]; then
    export PERF_PARTITION_READY="${PERF_PARTITION_READY:-0}"
  fi
fi
if [[ "${continuous_profiling:-0}" == "1" ]]; then
  resolve_profiling_policy "${scenario_id}" || {
    echo "continuous profiling policy rejected before traffic" >&2
    exit 1
  }
fi
if [[ "${PERF_WORKLOAD_KIND}" == "journey" || "${PERF_WORKLOAD_KIND}" == "mix" || "${PERF_MIX_KIND:-}" == "journey" ]] && [[ "${load_generator}" == "wrk" ]]; then
  echo "capability generator.wrk.journey is unsupported; rejected before traffic" >&2
  exit 1
fi
performance_manifest_selector_preflight "${workload_manifest:-}" "${scenario_id}" "${load_generator}" "${PERF_WORKLOAD_KIND:-request}" || exit 1
if [[ -n "${workload_manifest:-}" && -f "${workload_manifest}" ]]; then
  # A selector may declare a closed multi-origin journey set. Derive this from
  # the manifest, not a caller-provided PERF_ALLOWED_ORIGINS value, before even
  # readiness traffic can leave the host.
  if manifest_allowed_origins="$(performance_manifest_allowed_origins_preflight "${workload_manifest}" "${scenario_id}" "${base_url}")"; then
    if [[ -n "${manifest_allowed_origins}" ]]; then
      export PERF_ALLOWED_ORIGINS="${manifest_allowed_origins}"
    else
      unset PERF_ALLOWED_ORIGINS
    fi
  else
    echo "workload origin allowlist rejected before traffic" >&2
    exit 1
  fi
fi
performance_capability_preflight "${load_generator}" "${PERF_WORKLOAD_KIND:-request}" "${PERF_PROTOCOL:-}" || {
  echo "capability advertisement rejected before traffic" >&2
  exit 1
}
distributed_enabled=0
distributed_shards="${PERFLAB_SHARDS:-${PERF_SHARDS:-1}}"
distributed_agents="${PERFLAB_DISTRIBUTED_AGENT_URLS:-}"
distributed_target_origin=""
if [[ ! "${distributed_shards}" =~ ^[1-9][0-9]*$ ]]; then
  echo "PERFLAB_SHARDS must be a positive integer" >&2
  exit 1
fi
if (( distributed_shards > 1 )); then
  # C-3 supports exactly the deliberately closed k6 request protocol. It is
  # not a general remote command runner and it does not make JMeter extras
  # appear implemented merely because more than one agent exists.
  [[ "${PERFLAB_DISTRIBUTED:-0}" == "1" ]] || {
    echo "distributed shards require PERFLAB_DISTRIBUTED=1" >&2
    exit 1
  }
  [[ "${load_generator}" == "k6" && "${PERF_WORKLOAD_KIND:-request}" == "request" && "${method}" == "GET" && -z "${body}" ]] || {
    echo "distributed execution supports only the declared k6 GET request selector" >&2
    exit 1
  }
  case "${load_profile}" in steady|closed) ;; *)
    echo "distributed execution supports steady or closed k6 profiles only" >&2
    exit 1
  esac
  [[ -z "${PERF_HEADERS:-}" ]] || {
    echo "distributed execution refuses caller-supplied request headers; the v1 agent has a fixed target-owned request contract" >&2
    exit 1
  }
  performance_distributed_selector_preflight "${workload_manifest:-}" "${scenario_id}" "${load_generator}" "${PERF_WORKLOAD_KIND:-request}" || exit 1
  [[ -n "${distributed_agents}" && -n "${PERFLAB_DISTRIBUTED_TOKEN:-}" ]] || {
    echo "distributed execution requires PERFLAB_DISTRIBUTED_AGENT_URLS and the secret PERFLAB_DISTRIBUTED_TOKEN" >&2
    exit 1
  }
  IFS=',' read -r -a distributed_agent_list <<< "${distributed_agents}"
  (( ${#distributed_agent_list[@]} == distributed_shards )) || {
    echo "distributed execution requires exactly one declared agent URL per shard" >&2
    exit 1
  }
  for distributed_agent_url in "${distributed_agent_list[@]}"; do
    distributed_agent_origin="$(performance_origin_from_url "${distributed_agent_url}")" || exit 1
    [[ "${distributed_agent_url}" == "${distributed_agent_origin}" ]] || {
      echo "distributed agent URLs must be canonical origins without a path" >&2
      exit 1
    }
  done
  distributed_target_origin="$(performance_origin_from_url "${base_url}")" || exit 1
  [[ -x "${harness_core_dir}/distributed/agent.py" ]] || {
    echo "distributed k6 controller is unavailable at ${harness_core_dir}/distributed/agent.py" >&2
    exit 1
  }
  case "${PERFLAB_DISTRIBUTED_PARTIAL:-0}" in 0|1) ;; *)
    echo "PERFLAB_DISTRIBUTED_PARTIAL must be 0 or 1" >&2
    exit 1
  esac
  case "${PERFLAB_DISTRIBUTED_ALLOW_INSECURE_LOCAL:-0}" in 0|1) ;; *)
    echo "PERFLAB_DISTRIBUTED_ALLOW_INSECURE_LOCAL must be 0 or 1" >&2
    exit 1
  esac
  distributed_enabled=1
fi
profiling_preflight_json='{"captureState":"not-applicable","reason":"continuous profiling is disabled"}'
if [[ "${continuous_profiling:-0}" == "1" ]]; then
  profiling_preflight_json="$(performance_profiling_preflight)" || {
    echo "continuous profiling policy rejected before traffic" >&2
    exit 1
  }
fi
if [[ "${load_profile}" == "soak" ]]; then
  performance_session_preflight "${load_generator}" || {
    echo "soak rejected before traffic: ${load_generator} does not supply Start/Snapshot/Stop" >&2
    exit 1
  }
fi
performance_profile_preflight "${load_profile}" "${load_generator}" || {
  echo "canonical profile ${load_profile} rejected before traffic" >&2
  exit 1
}
run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
scenario_lower="$(printf '%s' "${scenario_id}" | tr '[:upper:]' '[:lower:]')"
telemetry_run_id="${PERFLAB_TELEMETRY_RUN_ID:-${scenario_lower}-${run_stamp}}"
package_run_id="${PERFLAB_PACKAGE_RUN_ID:-${telemetry_run_id}}"
artifact_dir="${PERFLAB_ARTIFACT_DIR:-${artifacts_root}/runs/${package_run_id}}"
suite_run_id="${PERFLAB_SUITE_RUN_ID:-}"
suite_scenario_index="${PERFLAB_SUITE_SCENARIO_INDEX:-}"
suite_scenario_count="${PERFLAB_SUITE_SCENARIO_COUNT:-}"

# The generated run id is not a user-configurable target header. Rejecting an
# override here covers every generator before a lease, readiness call, or load
# request can use it; otherwise a remote correlation probe could prove one ID
# while the workload transmitted another.
validate_target_headers || exit 1

mkdir -p "${artifact_dir}/benchmark" "${artifact_dir}/analysis"
printf '%s\n' "${profiling_preflight_json}" > "${artifact_dir}/analysis/profiling-preflight.json"
# telemetry/dependencies/runtime hold OWNED-target captures; a remote package has
# none, so creating them would leave misleading empty stubs. Local target only.
if [[ "${target_mode}" == "local" ]]; then
  mkdir -p "${artifact_dir}/telemetry" "${artifact_dir}/dependencies" "${artifact_dir}/runtime"
fi

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
if [[ "${load_profile}" == "soak" ]]; then
  performance_soak_cert_preflight "${effective_duration}" || exit 1
fi
dataset_identity="${PERFLAB_DATASET_IDENTITY:-seedScale=${SEED_SCALE:-default}}"
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
# remoteTelemetry records whether this remote run was "remote-observed" (window-
# scoped Prometheus/Tempo/Loki also read) so capture-evidence knows authoritatively
# what to capture even on a standalone re-invocation. Always false for local.
remote_telemetry_json=false; [[ "${remote_telemetry:-0}" == "1" ]] && remote_telemetry_json=true
remote_correlation_field=""
if [[ "${target_mode}" == "remote" && "${remote_correlation:-0}" == "1" ]]; then
  correlation_proof="${artifact_dir}/analysis/remote-correlation.json"
  performance_remote_correlation_probe "${base_url}" "${telemetry_run_id}" "${correlation_proof}" || {
    echo "Refusing remote traffic because the target did not prove the run-id correlation contract." >&2
    exit 1
  }
  remote_correlation_field="$(printf ',\"remoteCorrelation\":{\"enabled\":true,\"verified\":true,\"version\":\"%s\",\"probePath\":\"%s\",\"header\":\"%s\",\"responseRunIdField\":\"%s\",\"responseVersionField\":\"%s\",\"prometheusLabel\":\"%s\",\"lokiLabel\":\"%s\",\"tempoAttribute\":\"%s\",\"proof\":\"analysis/remote-correlation.json\"}' \\
    "$(json_escape "${remote_correlation_version}")" "$(json_escape "${remote_correlation_probe_path}")" \\
    "$(json_escape "${remote_correlation_header}")" "$(json_escape "${remote_correlation_response_run_id_field}")" \\
    "$(json_escape "${remote_correlation_response_version_field}")" "$(json_escape "${remote_correlation_prometheus_label}")" \\
    "$(json_escape "${remote_correlation_loki_label}")" "$(json_escape "${remote_correlation_tempo_attribute}")")"
fi
distributed_field=""
if [[ "${distributed_enabled}" == "1" ]]; then
  distributed_field="$(printf ',"distributed":{"enabled":true,"protocol":"perflab-distributed/v1","shards":%s,"agents":%s,"targetOrigin":"%s","tokenReference":"secret://PERFLAB_DISTRIBUTED_TOKEN","partialAllowed":%s}' \
    "${distributed_shards}" "$(jqd -cn '$ARGS.positional' --args "${distributed_agent_list[@]}")" \
    "$(json_escape "${distributed_target_origin}")" \
    "$([[ "${PERFLAB_DISTRIBUTED_PARTIAL:-0}" == "1" ]] && echo true || echo false)")"
fi
continuous_profiling_json=false; [[ "${continuous_profiling:-0}" == "1" ]] && continuous_profiling_json=true
profiling_keep_tiering_json=false
[[ "${continuous_profiling:-0}" == "1" && "${profiling_keep_tiering:-0}" == "1" ]] && profiling_keep_tiering_json=true
printf '{"runId":"%s","telemetryRunId":"%s","scenarioId":"%s","mode":"measure","target":"%s","remoteTelemetry":%s,"continuousProfiling":%s,"profilingKeepTiering":%s,"profilingPolicy":"%s","profilingPolicySource":"%s","profilingTypes":"%s","traceSampler":"%s","traceSamplerArg":"%s","profilingPreflight":"analysis/profiling-preflight.json","workload":{"loadGenerator":"%s","baseUrl":"%s","readyUrl":"%s","method":"%s","path":"%s","body":"%s","datasetIdentity":"%s","durationSeconds":%s,"requestedDurationSeconds":%s,"connections":%s,"profile":"%s"},"startedAt":"%s","startedEpoch":%s,"source":{"gitRevision":"%s"}%s%s%s%s}\n' \
  "$(json_escape "${package_run_id}")" "$(json_escape "${telemetry_run_id}")" "$(json_escape "${scenario_id}")" "$(json_escape "${target_mode}")" "${remote_telemetry_json}" "${continuous_profiling_json}" "${profiling_keep_tiering_json}" \
  "$(json_escape "${PERFLAB_PROFILING_POLICY}")" "$(json_escape "${PERFLAB_PROFILING_POLICY_SOURCE:-default}")" "$(json_escape "${PERFLAB_PROFILING_TYPES}")" \
  "$(json_escape "${PERFLAB_TRACE_SAMPLER:-parentbased_traceidratio}")" "$(json_escape "${PERFLAB_TRACE_SAMPLE_RATIO:-0.25}")" \
  "$(json_escape "${load_generator}")" "$(json_escape "${base_url}")" "$(json_escape "${ready_url}")" "$(json_escape "${method}")" "$(json_escape "${path}")" "$(json_escape "${body}")" "$(json_escape "${dataset_identity}")" \
  "${effective_duration}" "${duration_seconds}" "${connections}" "$(json_escape "${load_profile}")" "$(json_escape "${started_at}")" "${started_epoch}" \
  "$(json_escape "${git_revision}")" "${suite_field}" "${fault_field}" "${remote_correlation_field}" "${distributed_field}" \
  > "${artifact_dir}/manifest.json"

export PERF_SCENARIO="${perf_scenario}" PERF_RUN_ID="${telemetry_run_id}" PERF_RUN_MODE="measure"
export PERF_METHOD="${method}" PERF_PATH="${path}" PERF_BODY="${body}" PERF_BASE_URL="${base_url}"
export PERF_WORKLOAD_KIND="${PERF_WORKLOAD_KIND:-request}"
export PERFLAB_CONNECTIONS="${connections}" PERFLAB_DURATION_SECONDS="${duration_seconds}" PERFLAB_PROFILE="${load_profile}"

managed_partition_required=0
if [[ "${PERF_WORKLOAD_KIND}" == "journey" || "${PERF_MIX_KIND:-}" == "journey" || "${PERF_REQUIRES_MANAGED_PARTITION:-0}" == "1" ]]; then
  managed_partition_required=1
  export PERF_REQUIRES_MANAGED_PARTITION=1
fi

partition_cleanup_required=0
partition_cleanup_done=0
cleanup_partition() {
  [[ "${partition_cleanup_required}" == "1" && "${partition_cleanup_done}" == "0" ]] || return 0
  partition_cleanup_done=1
  if bash "${harness_core_dir}/datafault/managed-reference.sh" "${telemetry_run_id}" "${base_url}" cleanup; then
    : > "${artifact_dir}/cleanup-complete"
  else
    : > "${artifact_dir}/cleanup-incomplete"
    export PERFLAB_CAPTURE_INCOMPLETE=1
  fi
  return 0
}

if [[ "${target_mode}" == "remote" ]]; then
  # Remote target: the app is already deployed and is NOT owned here. No Compose
  # lifecycle, no dependency resets -- a black-box load test against base_url whose
  # only evidence is the load generator's own SLIs. Just confirm it is reachable.
  echo "Remote target ${base_url} for ${scenario_id} (${telemetry_run_id}) -- no lifecycle/reset."
  # The workload is REAL traffic against a live target: a non-GET method mutates
  # remote data. The tiers never touch lifecycle or owned dependencies, but the load
  # itself is not "read-only" for a write scenario -- say so loudly.
  case "${method}" in
    GET|HEAD) : ;;
    *) echo "WARNING: scenario ${scenario_id} uses ${method} -- this drives REAL ${method} traffic and may MUTATE data on the remote target ${base_url}." >&2 ;;
  esac
  # Fail CLOSED on an unreachable target: generating load against a down or unhealthy
  # staging/production endpoint can deepen an outage. Override deliberately with
  # PERFLAB_REMOTE_ALLOW_UNHEALTHY=1 to load a target expected to be degraded (or when
  # the readiness endpoint itself requires auth this bare check cannot supply).
  if ! target_curl -fsS --max-time 10 "${ready_url}" >/dev/null 2>&1; then
    if [[ "${PERFLAB_REMOTE_ALLOW_UNHEALTHY:-0}" == "1" ]]; then
      echo "WARNING: remote readiness check failed at ${ready_url}; PERFLAB_REMOTE_ALLOW_UNHEALTHY=1 set, measuring anyway." >&2
      export PERFLAB_CAPTURE_INCOMPLETE=1
    else
      echo "ERROR: remote readiness check failed at ${ready_url}. Refusing to generate load against an unhealthy target; set PERFLAB_REMOTE_ALLOW_UNHEALTHY=1 to override." >&2
      exit 1
    fi
  fi
elif [[ "${target_owned}" != "1" ]]; then
  # C-5. A LOCAL target this run did not create: an already-running process or
  # container the operator points us at. Previously every non-remote target went
  # down the Compose path and then hit the ownership guard, so `existing-process`
  # could only ever REFUSE -- the guard existed but the capability it was meant
  # to make safe did not. Attach-only is the whole point: measure and diagnose
  # without deploying, resetting or stopping anything.
  echo "Attaching to an existing ${target_kind} for ${scenario_id} (${telemetry_run_id}) -- no deploy, no reset, no teardown."
  if [[ "${continuous_profiling:-0}" == "1" && "${PERFLAB_PROFILING_TYPES}" != "cpu" ]]; then
    echo "cannot apply profiling policy ${PERFLAB_PROFILING_POLICY} (types ${PERFLAB_PROFILING_TYPES}) to an unowned target; Pyroscope types are process-lifetime. Attach only with a matching running profiler, or use managed-compose." >&2
    exit 1
  fi
  performance_target_preflight "${target_kind}" attach measure || {
    echo "attach-only target refused measurement" >&2
    exit 1
  }
  # We did not start it, so we cannot assume it is up. Fail closed rather than
  # measure a target that is not serving: the numbers would be a readiness
  # failure wearing a latency result.
  if ! target_curl -fsS --max-time 10 "${ready_url}" >/dev/null 2>&1; then
    echo "ERROR: ${ready_url} is not ready and this run did not start the target, so it cannot bring it up." >&2
    echo "  Start the process or container yourself, or use PERFLAB_TARGET_KIND=managed-compose to let the harness own it." >&2
    exit 1
  fi
  # Dependency state is NOT ours to reset, and that must travel with the
  # evidence: a comparison against a managed run happened over a dataset this
  # run neither prepared nor fingerprinted, and reading the two as equivalent is
  # the mistake the record exists to prevent.
  data_state_dir="${artifact_dir}/data"
  mkdir -p "${data_state_dir}"
  printf '{"datasetIdentity":"%s","seedScale":"%s","dependencies":"%s","resetAt":null,"resetFailures":0,"interruptionRecovered":false,"owned":false,"reason":"attach-only target (%s): dependency state belongs to whoever created it"}\n' \
    "$(json_escape "unowned:${target_kind}")" "$(json_escape "${SEED_SCALE:-unknown}")" \
    "$(json_escape "${dependencies}")" "$(json_escape "${target_kind}")" > "${data_state_dir}/dataset.json"
  export PERFLAB_CAPTURE_INCOMPLETE=1
else
  echo "Starting local stack for ${scenario_id} (${telemetry_run_id})..."
  performance_target_preflight managed-compose managed deploy || {
    echo "local compose target refused deploy/start before compose up" >&2
    exit 1
  }
  # Free the shared host ports first: other labs bind the same 8080/5432/etc.
  require_target_ownership "start and rebuild the application stack" || exit 1
  stop_conflicting_lab_stacks
  profiling_stamp="${artifacts_root}/.applied-profiling-startup"
  profiling_key="$(profiling_startup_key)"
  if [[ "${continuous_profiling:-0}" == "1" ]] && profiling_needs_recreate "$(cat "${profiling_stamp}" 2>/dev/null || true)" "${profiling_key}"; then
    echo "profiler startup config changed; recreating owned app so Pyroscope types match the selected policy"
    # shellcheck disable=SC2086
    compose up -d --build --force-recreate ${app_services}
  else
    # shellcheck disable=SC2086
    compose up -d --build ${app_services}
  fi
  if [[ "${continuous_profiling:-0}" == "1" ]]; then
    printf '%s\n' "${profiling_key}" > "${profiling_stamp}"
  fi
  wait_for_api

  # C-6. Dependency resets so the run is scenario-scoped. Three properties the
  # previous loop did not have:
  #
  #  - OWNERSHIP: a reset truncates state. Against a target this run did not
  #    create, that is somebody else's data.
  #  - INTERRUPTION RECOVERY: a run killed between reset and measurement leaves
  #    the dataset half-prepared, and the next run silently measures it. The
  #    marker records intent BEFORE the reset, so the next run can see that the
  #    previous one did not finish and redo the preparation rather than trust it.
  #  - FINGERPRINT: what the data WAS is part of the measurement. Two runs over
  #    different datasets are not comparable, and without a recorded fingerprint
  #    that difference is invisible in the evidence.
  require_target_ownership "reset owned dependency state" || exit 1
  data_state_dir="${artifact_dir}/data"
  mkdir -p "${data_state_dir}"
  data_marker="${artifacts_root}/.dataset-preparation"
  # Capture this BEFORE the marker is rewritten and removed below. Reading the
  # marker after the reset always answered "no interruption", which is the one
  # answer it can never usefully give -- the field existed but could not carry
  # the fact it was created to record.
  interruption_recovered=false
  if [[ -f "${data_marker}" ]]; then
    interruption_recovered=true
    echo "NOTE: a previous run did not finish preparing the dataset ($(cat "${data_marker}" 2>/dev/null || echo unknown)); re-running every reset rather than measuring a half-prepared dataset." >&2
  fi
  printf '{"runId":"%s","startedAt":"%s"}\n' \
    "$(json_escape "${telemetry_run_id}")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${data_marker}"
  reset_failures=0
  for dep in ${dependencies}; do
    # Resets are idempotent by contract, so re-running after an interrupted run
    # is safe; a FAILED reset is not, because the measurement would then run
    # against state the run believes it cleared.
    if ! "$(dependency_dir "${dep}")/reset.sh" "${artifact_dir}"; then
      echo "WARNING: ${dep} reset failed; the measurement would start from state this run did not clear." >&2
      reset_failures=$((reset_failures + 1))
    fi
  done
  if [[ "${reset_failures}" -gt 0 ]]; then
    echo "Refusing to measure after ${reset_failures} failed dependency reset(s)." >&2
    exit 1
  fi
  # A CONTENT fingerprint, not just the declared scale. The declaration says
  # what was asked for; a reset that silently half-restored produces the same
  # declaration as one that worked, so comparing two runs on the declaration
  # alone cannot tell those apart. Each dependency that can describe its own
  # state contributes, and the digest covers all of them together.
  # Built as a FILE, not a shell string: `$( )` strips NUL bytes, so the record
  # separator silently vanished and two different dependency/output splits could
  # hash identically -- while every run printed an "ignored null byte" warning.
  dataset_content_file="${data_state_dir}/.content"
  : > "${dataset_content_file}"
  dataset_fingerprint_failures=0
  dataset_fingerprint_sources=0
  for dep in ${dependencies}; do
    dep_fingerprint="$(dependency_dir "${dep}")/fingerprint.sh"
    [[ -x "${dep_fingerprint}" ]] || continue
    dataset_fingerprint_sources=$((dataset_fingerprint_sources + 1))
    printf '%s\n' "== ${dep}" >> "${dataset_content_file}"
    # A fingerprint that FAILED is not an empty dataset. Swallowing the failure
    # produced a digest over partial input and called it captured, so two runs
    # whose fingerprints both failed hashed identically and compared as equal.
    if ! bash "${dep_fingerprint}" >> "${dataset_content_file}" 2>/dev/null; then
      dataset_fingerprint_failures=$((dataset_fingerprint_failures + 1))
      echo "WARNING: ${dep} fingerprint failed; the dataset cannot be identified by content." >&2
    fi
  done
  if [[ "${dataset_fingerprint_sources}" -gt 0 && "${dataset_fingerprint_failures}" -eq 0 ]]; then
    dataset_content_sha="$({ command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } < "${dataset_content_file}" | awk '{print $1}')"
    dataset_content_state="captured"
  elif [[ "${dataset_fingerprint_failures}" -gt 0 ]]; then
    dataset_content_sha=""
    dataset_content_state="failed"
  else
    # No dependency could describe its state. That is "not measured", not
    # "identical" -- recording a constant here would make every run look
    # comparable to every other.
    dataset_content_sha=""
    dataset_content_state="not-captured"
  fi
  printf '{"datasetIdentity":"%s","seedScale":"%s","dependencies":"%s","resetAt":"%s","resetFailures":%s,"interruptionRecovered":%s,"contentFingerprint":{"captureState":"%s","sha256":"%s"}}\n' \
    "$(json_escape "${dataset_identity}")" "$(json_escape "${SEED_SCALE:-default}")" \
    "$(json_escape "${dependencies}")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${reset_failures}" \
    "${interruption_recovered}" "${dataset_content_state}" "${dataset_content_sha}" > "${data_state_dir}/dataset.json"
  if [[ "${managed_partition_required}" == "1" ]]; then
    if [[ "${PERF_WRITE_ACK:-}" != "managed-reference" ]]; then
      echo "managed-reference journey requires explicit PERF_WRITE_ACK=managed-reference" >&2
      exit 1
    fi
    if [[ ! "${PERF_WRITE_BUDGET:-}" =~ ^[1-9][0-9]*$ ]]; then
      echo "managed-reference journey requires an explicit positive PERF_WRITE_BUDGET" >&2
      exit 1
    fi
    # Arm the cleanup BEFORE the mutation, not after. Creating the partition and
    # then registering the trap leaves a window where a failure part-way through
    # setup -- or an interrupt during it -- exits with the partition created and
    # nothing responsible for removing it. Cleanup is idempotent, so arming it
    # early costs nothing when there is nothing yet to remove.
    partition_cleanup_required=1
    trap cleanup_partition INT TERM EXIT
    bash "${harness_core_dir}/datafault/managed-reference.sh" "${telemetry_run_id}" "${base_url}"
    export PERF_PARTITION_READY=1
  fi
fi

echo "Warming up for ${PERFLAB_WARMUP_SECONDS:-10} seconds with ${load_generator}..."
loadgen_warmup "${artifact_dir}"

if [[ "${target_mode}" == "local" && "${managed_partition_required}" == "1" ]]; then
  bash "${harness_core_dir}/datafault/managed-reference.sh" "${telemetry_run_id}" "${base_url}" reset
fi

# Dataset preparation is complete only now: the resets ran, any managed-reference
# partition was created and reset, and warm-up finished. Clearing the marker
# after the resets alone left an interruption during partition preparation or
# warm-up invisible, so the next run measured a half-prepared dataset while the
# marker promised to cover "between reset and measurement".
if [[ -n "${data_marker:-}" ]]; then
  rm -f "${data_marker}"
fi

# Reset cumulative-since-reset dependency statistics (pg_stat_statements, redis
# stat counters/slowlog/latency) AFTER warm-up, so those snapshots reflect the
# MEASURE phase only. The range-gauge telemetry is already windowed to the measure
# phase, but these counters would otherwise accumulate from the pre-warm-up reset
# and fold ~10s of warm-up traffic into the evidence. Data/cache is left intact.
# Local-only: a remote target's dependencies are not owned or reachable here.
if [[ "${target_mode}" == "local" ]]; then
  for dep in ${dependencies}; do
    reset_stats="$(dependency_dir "${dep}")/reset-stats.sh"
    if [[ -f "${reset_stats}" ]]; then
      bash "${reset_stats}" "${artifact_dir}" \
        || { echo "WARNING: ${dep} reset-stats failed; its cumulative counters still include warm-up." >&2; export PERFLAB_CAPTURE_INCOMPLETE=1; }
    fi
  done
fi

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
  local inject_ok=0 restore_ok=0 window_held=0
  local apply_state="" end_state="" restore_state="" container_id=""
  local apply_at="" end_at="" restore_at=""
  case "${kind}" in
    stop) compose stop "${dep}" >/dev/null 2>&1 || true ;;
    kill) compose kill "${dep}" >/dev/null 2>&1 || true ;;
    *) compose pause "${dep}" >/dev/null 2>&1 || true ;;
  esac
  apply_state="$(performance_compose_service_state "${dep}")"
  apply_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  container_id="$(performance_compose_service_id "${dep}")"
  if performance_fault_state_applied "${kind}" "${apply_state}"; then inject_ok=1; fi
  sleep "${dur}"
  end_state="$(performance_compose_service_state "${dep}")"
  end_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ "${inject_ok}" == "1" ]] && performance_fault_state_applied "${kind}" "${end_state}"; then
    window_held=1
  elif [[ "${inject_ok}" == "1" ]]; then
    echo "[fault] WARNING: '${kind} ${dep}' recovered before the ${dur}s window ended (state=${end_state:-empty})." >&2
  fi
  case "${kind}" in
    stop|kill) compose start "${dep}" >/dev/null 2>&1 || true ;;
    *) compose unpause "${dep}" >/dev/null 2>&1 || true ;;
  esac
  restore_state="$(performance_compose_service_state "${dep}")"
  restore_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if performance_fault_state_restored "${restore_state}"; then restore_ok=1; fi
  [[ "${inject_ok}" == "1" ]] || echo "[fault] WARNING: '${kind} ${dep}' did NOT take effect; this run did not inject the fault." >&2
  if [[ "${restore_ok}" == "1" ]]; then
    echo "[fault] ${dep} restored"
  else
    echo "[fault] WARNING: could not restore ${dep} inline; the cleanup trap will retry." >&2
  fi
  mkdir -p "${artifact_dir}/benchmark"
  printf '{"action":"%s","service":"%s","containerId":"%s","applied":%s,"windowHeld":%s,"restored":%s,"appliedState":"%s","endState":"%s","restoredState":"%s","appliedAt":"%s","endedAt":"%s","restoredAt":"%s"}\n' \
    "$(json_escape "${kind}")" "$(json_escape "${dep}")" "$(json_escape "${container_id}")" \
    "$([[ "${inject_ok}" == "1" ]] && echo true || echo false)" \
    "$([[ "${window_held}" == "1" ]] && echo true || echo false)" \
    "$([[ "${restore_ok}" == "1" ]] && echo true || echo false)" \
    "$(json_escape "${apply_state}")" "$(json_escape "${end_state}")" "$(json_escape "${restore_state}")" \
    "$(json_escape "${apply_at}")" "$(json_escape "${end_at}")" "$(json_escape "${restore_at}")" \
    > "${artifact_dir}/benchmark/fault-proof.json"
  if   [[ "${inject_ok}"  != "1" ]]; then return 1
  elif [[ "${window_held}" != "1" ]]; then return 3
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
  [[ -n "${load_pid:-}" ]]    && { kill "${load_pid}"    2>/dev/null || true; wait "${load_pid}"    2>/dev/null || true; }
  [[ -n "${PERFLAB_FAULT_DEP:-}" ]] || return 0
  compose unpause "${PERFLAB_FAULT_DEP}" >/dev/null 2>&1 || true
  compose start "${PERFLAB_FAULT_DEP}" >/dev/null 2>&1 || true
}

# Baseline BEFORE any load: distinguishes "the app slowed down" from "the
# host was already loaded when we started".
"${harness_core_dir}/capture/capture-environment.sh" "${artifact_dir}" pre-run >/dev/null 2>&1 || true
echo "Measuring for ${effective_duration}s at ${connections} connections with ${load_generator}..."
if [[ "${load_profile}" == "soak" ]]; then
  mkdir -p "${artifact_dir}/benchmark/session"
  if [[ -f "${artifact_dir}/benchmark/session/start.json" ]]; then
    echo "soak session already started; generator restart refused" >&2
    exit 1
  fi
fi
midload_pid=""; fault_pid=""
if [[ "${target_mode}" == "local" ]]; then
  if [[ -n "${PERFLAB_FAULT_DEP:-}" || "${partition_cleanup_required}" == "1" ]]; then
    trap 'restore_fault_dep; cleanup_partition' INT TERM EXIT
  fi
  # Mid-load sampling and fault injection both act on OWNED dependencies/compose,
  # so they run only for a local target. A remote target measures the load
  # generator's SLIs against base_url with no dependency/compose probing.
  sample_midload & midload_pid=$!
  inject_fault & fault_pid=$!
fi
# Boundary environment snapshots (phase envelope). Best-effort: the
# environment contextualises a verdict, it never IS the verdict.
"${harness_core_dir}/capture/capture-environment.sh" "${artifact_dir}" measurement-start >/dev/null 2>&1 || true
measure_started_epoch="$(date -u +%s)"
measurement_window_start=""
measurement_window_end=""
measurement_window_id=""
if [[ -n "${PERFLAB_MEASUREMENT_WINDOW_PROBE_PATH:-}" ]]; then
  # This is the last target-owned identity check before a measured request can
  # leave the generator. It binds the exact run to the concrete process
  # generation rather than trusting a stale service-instance series.
  measurement_window_id="mw-${measure_started_epoch}-${scenario_lower}"
  measurement_window_start="${artifact_dir}/analysis/measurement-window-start.json"
  performance_measurement_window_probe "${base_url}" "${telemetry_run_id}" "${measurement_window_id}" start "${measurement_window_start}" || {
    echo "measurement-window start attestation failed before traffic" >&2
    exit 1
  }
fi
distributed_measure() {
  local python_executable
  python_executable="$(perflab_python)" || {
    echo "a working Python 3 interpreter was not found (tried python3, python)" >&2
    exit 1
  }
  local -a command=("${python_executable}" "${harness_core_dir}/distributed/agent.py" controller
    --agents "${distributed_agents}" --shards "${distributed_shards}"
    --target-origin "${distributed_target_origin}" --duration-seconds "${effective_duration}"
    --connections "${connections}" --run-id "${telemetry_run_id}"
    --artifact-dir "${artifact_dir}")
  [[ "${PERFLAB_DISTRIBUTED_PARTIAL:-0}" == "1" ]] && command+=(--allow-partial)
  [[ "${PERFLAB_DISTRIBUTED_ALLOW_INSECURE_LOCAL:-0}" == "1" ]] && command+=(--allow-insecure-local)
  "${command[@]}"
}
distributed_sha256_stream() {
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    echo "distributed compatibility capture needs openssl or shasum for SHA-256." >&2
    return 1
  fi
}
distributed_write_compatibility() {
  # The closed controller writes aggregate evidence, not the normal local k6
  # adapter's envelope.  Make the package comparable only after binding it to
  # the immutable embedded workload and the one generator fingerprint all
  # admitted agents registered. Never substitute the controller host's k6
  # version: it did not generate the measured traffic.
  local aggregate plan fingerprint plan_fingerprint script script_rel workload_hash config_hash topology timeout_seconds partial_loss
  aggregate="${artifact_dir}/benchmark/distributed-aggregate.json"
  plan="${artifact_dir}/benchmark/distributed-plan.json"
  [[ -s "${aggregate}" && -s "${plan}" ]] || {
    echo "distributed controller did not publish aggregate and plan evidence" >&2
    return 1
  }
  fingerprint="$(jqd -r '.generatorFingerprint // empty' < "${aggregate}")"
  plan_fingerprint="$(jqd -r '.generatorFingerprint // empty' < "${plan}")"
  [[ "${fingerprint}" =~ ^sha256:[a-f0-9]{64}$ && "${fingerprint}" == "${plan_fingerprint}" ]] || {
    echo "distributed controller did not bind one valid k6 fingerprint to the aggregate and plan" >&2
    return 1
  }
  script="${harness_core_dir}/distributed/k6-distributed.js"
  [[ -f "${script}" ]] || { echo "distributed fixed k6 workload is missing" >&2; return 1; }
  script_rel="$(relative_to_repo "${script}")"
  workload_hash="$({ printf '%s\0' "${script_rel}"; cat "${script}"; printf '\0'; } | distributed_sha256_stream)"
  topology="$(jqd -c '[.shards[] | {id,agentURL,connections,executionSegment}] | sort_by(.id)' < "${plan}")"
  partial_loss="$(jqd -r '.partialLoss // false' < "${aggregate}")"
  [[ "${partial_loss}" == "true" || "${partial_loss}" == "false" ]] || {
    echo "distributed aggregate has an invalid partial-loss declaration" >&2
    return 1
  }
  timeout_seconds=$((effective_duration + 75))
  config_hash="$({
    printf 'protocol\0%s\0fingerprint\0%s\0agents\0%s\0connections\0%s\0duration\0%s\0timeout\0%s\0profile\0%s\0scenario\0%s\0' \
      'perflab-distributed/v1' "${fingerprint}" "${topology}" "${connections}" "${effective_duration}" "${timeout_seconds}s" "${load_profile}" "${scenario_id}"
    printf 'baseUrl\0%s\0method\0%s\0path\0%s\0network\0%s\0script\0%s\0partialLoss\0%s\0' \
      "${base_url%/}" "${method}" "${path}" 'distributed-agent' "${script_rel}" "${partial_loss}"
  } | distributed_sha256_stream)"
  [[ "${workload_hash}" =~ ^[a-f0-9]{64}$ && "${config_hash}" =~ ^[a-f0-9]{64}$ ]] || {
    echo "distributed compatibility fingerprint/hash capture failed" >&2
    return 1
  }
  printf '{"generator":"k6","generatorFingerprint":"%s","workloadContentHash":"%s","configurationHash":"%s","networkPath":"distributed-agent","timeout":"%ss","durationSeconds":%s,"connections":%s,"scenario":"%s","profile":"%s","baseUrl":"%s","method":"%s","path":"%s","script":"%s","distributedProtocol":"perflab-distributed/v1","agentCount":%s,"partialLoss":%s}\n' \
    "$(json_escape "${fingerprint}")" "${workload_hash}" "${config_hash}" "${timeout_seconds}" "${effective_duration}" "${connections}" \
    "$(json_escape "${scenario_id}")" "$(json_escape "${load_profile}")" "$(json_escape "${base_url%/}")" \
    "$(json_escape "${method}")" "$(json_escape "${path}")" "$(json_escape "${script_rel}")" "${distributed_shards}" "${partial_loss}" \
    > "${artifact_dir}/benchmark/compatibility.json"
}
load_pid=""
load_rc=0
if [[ "${load_profile}" == "soak" ]]; then
  snapshot_interval="${PERFLAB_SOAK_SNAPSHOT_SECONDS:-300}"
  [[ "${snapshot_interval}" =~ ^[1-9][0-9]*$ ]] || { echo "PERFLAB_SOAK_SNAPSHOT_SECONDS must be a positive integer" >&2; exit 1; }
  loadgen_measure "${artifact_dir}" measure & load_pid=$!
  performance_soak_bind_pid "${artifact_dir}/benchmark/session/start.json" "${load_pid}" "${load_generator}" "${measure_started_epoch}" || exit 1
  soak_identity="$(performance_soak_identity "${artifact_dir}/benchmark/session/start.json")" || exit 1
  [[ -n "${soak_identity}" ]] || { echo "soak generator identity was empty" >&2; exit 1; }
  next_snapshot=$((measure_started_epoch + snapshot_interval))
  while kill -0 "${load_pid}" 2>/dev/null; do
    now_epoch="$(date -u +%s)"
    performance_soak_assert_pid "${artifact_dir}/benchmark/session/start.json" "${load_pid}" || exit 1
    printf '{"event":"heartbeat","atEpoch":%s,"generatorPid":%s,"generatorIdentity":"%s"}\n' "${now_epoch}" "${load_pid}" "${soak_identity}" \
      >> "${artifact_dir}/benchmark/session/heartbeats.ndjson"
    if (( now_epoch >= next_snapshot )); then
      printf '{"event":"snapshot","atEpoch":%s,"generatorPid":%s,"generatorIdentity":"%s"}\n' "${now_epoch}" "${load_pid}" "${soak_identity}" \
        >> "${artifact_dir}/benchmark/session/snapshots.ndjson"
      next_snapshot=$((now_epoch + snapshot_interval))
    fi
    sleep 5
  done
  load_rc=0
  wait "${load_pid}" || load_rc=$?
  load_pid=""
else
  if [[ "${distributed_enabled}" == "1" ]]; then
    distributed_measure || load_rc=$?
  else
    loadgen_measure "${artifact_dir}" measure || load_rc=$?
  fi
fi
measure_ended_epoch="$(date -u +%s)"
if [[ -n "${measurement_window_start}" ]]; then
  measurement_window_end="${artifact_dir}/analysis/measurement-window-end.json"
  performance_measurement_window_probe "${base_url}" "${telemetry_run_id}" "${measurement_window_id}" end "${measurement_window_end}" || {
    echo "measurement-window end attestation failed; evidence cannot be scoped to an exact target generation" >&2
    exit 1
  }
  performance_measurement_window_finalize "${measurement_window_start}" "${measurement_window_end}" \
    "${artifact_dir}/analysis/measurement-window.json" || {
    echo "measurement-window evidence could not be finalized" >&2
    exit 1
  }
fi
if (( load_rc != 0 )); then
  if [[ "${load_profile}" == "soak" ]]; then
    echo "soak generator exited with status ${load_rc}" >&2
  else
    echo "load generator exited with status ${load_rc}" >&2
  fi
  exit "${load_rc}"
fi
if [[ "${distributed_enabled}" == "1" ]]; then
  distributed_write_compatibility || {
    echo "distributed measured evidence did not publish a valid compatibility envelope" >&2
    exit 1
  }
fi
"${harness_core_dir}/capture/capture-environment.sh" "${artifact_dir}" measurement-end >/dev/null 2>&1 || true
if [[ "${load_profile}" == "soak" ]]; then
  printf '{"event":"snapshot","atEpoch":%s,"generatorIdentity":"%s","final":true}\n' "${measure_ended_epoch}" "${soak_identity}" \
    > "${artifact_dir}/benchmark/session/snapshot.json"
  printf '{"event":"stop","generator":"%s","generatorIdentity":"%s"}\n' "$(json_escape "${load_generator}")" "${soak_identity}" \
    > "${artifact_dir}/benchmark/session/stop.json"
fi
[[ -n "${midload_pid}" ]] && { wait "${midload_pid}" 2>/dev/null || true; }
fault_rc=0; [[ -n "${fault_pid}" ]] && { wait "${fault_pid}" 2>/dev/null || fault_rc=$?; }
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
cleanup_partition

"${harness_core_dir}/capture/capture-evidence.sh" "${artifact_dir}"

# Server-side analyzers read Prometheus. A black-box remote measurement must not
# query it just because the URL is reachable; write an explicit not-applicable
# analysis instead of a quiet empty/insufficient-data placeholder.
if [[ "${target_mode}" == "local" || "${remote_telemetry:-0}" == "1" ]]; then
  # Resource-trend / leak detection on the captured range gauges (heap, working
  # set, thread-pool queue, DB connections). This is the soak profile's payload --
  # the growth signal a long run exists to surface -- but it is cheap and useful on
  # any run (short windows self-mark as low-confidence).
  "${harness_core_dir}/analyze/analyze-trends.sh" "${artifact_dir}" || true

  # Steady-state validity: did the measure window actually settle, or did warm-up
  # transients (JIT, pool/cache fill, GC) skew the reported p99/throughput/efficiency?
  # Reads window-local SERVER metrics (request-count rate + duration-histogram quantile);
  # best-effort and skippable (PERFLAB_STEADY_STATE=0). It reports; gate.sh
  # --require-steady enforces.
  if [[ "${PERFLAB_STEADY_STATE:-1}" != "0" ]]; then
    "${harness_core_dir}/analyze/steady-state.sh" "${artifact_dir}" || true
  fi

  # USE-method bottleneck classification (CPU / thread pool / GC / locks / DB pool /
  # dependency) from the captured evidence -- a reproducible "what is the bottleneck?"
  # answer next to the AI phase's. Best-effort and skippable (PERFLAB_BOTTLENECK=0).
  # Environment drift across the run boundaries. A measurement is comparable to
  # another only if the machine was the same machine, and the snapshots that can
  # answer that are worthless unless something reads them.
  "${harness_core_dir}/analyze/environment-drift.sh" "${artifact_dir}" >/dev/null 2>&1 || true

  # Accepted-versus-completed reconciliation for broker-backed scenarios. An
  # async endpoint returns 202 once it has enqueued, so HTTP metrics report
  # success for work that may never happen; the broker evidence is the only
  # place that shows it.
  "${harness_core_dir}/analyze/async-reconciliation.sh" "${artifact_dir}" >/dev/null 2>&1 || true

  if [[ "${PERFLAB_BOTTLENECK:-1}" != "0" ]]; then
    "${harness_core_dir}/analyze/bottleneck.sh" "${artifact_dir}" || true
    # Human-readable entry point. Regenerated after runtime normalization
    # too, so a retention finding that only the gcdump pair can see reaches
    # the page instead of only the JSON.
    "${harness_core_dir}/analyze/report.sh" "${artifact_dir}" >/dev/null 2>&1 || true
  fi
else
  echo "Remote (black-box): skipping Prometheus-backed analyzers; recording not-applicable server analysis." >&2
  mkdir -p "${artifact_dir}/analysis"
  window=$(( measure_ended_epoch - measure_started_epoch )); (( window < 1 )) && window=1
  printf '{"kind":"steady-state","runId":"%s","scenarioId":"%s","profile":"%s","verdict":"not-applicable","windowSeconds":%s,"basis":"server-side windowed (http_server_request_duration histogram)","reason":"server telemetry was not collected for this black-box remote measurement"}\n' \
    "$(json_escape "${telemetry_run_id}")" "$(json_escape "${scenario_id}")" "$(json_escape "${load_profile}")" "${window}" \
    > "${artifact_dir}/analysis/steady-state.json"
  printf '{"kind":"trend-report","verdict":"not-applicable","growthThreshold":0.2,"series":[],"reason":"server telemetry was not collected for this black-box remote measurement"}\n' \
    > "${artifact_dir}/analysis/trend-report.json"
fi

# Record this run's key facts to the committed cross-commit perf history
# (perf-history/<lab>.jsonl) so trend-report.sh can show the metric per scenario
# over time. Best-effort and skippable (PERFLAB_RECORD_TREND=0); never fails the run.
if [[ "${PERFLAB_RECORD_TREND:-1}" != "0" ]]; then
  "${harness_core_dir}/analyze/record-trend.sh" "${artifact_dir}" || true
fi

echo "Evidence package: ${artifact_dir}"
# Runtime diagnostics (nettrace/gcdump/stacks) need a dotnet-monitor endpoint: a
# local target owns its sidecar; a remote target must opt in (PERFLAB_REMOTE_
# DIAGNOSTICS=1 + ack) and point at a reachable remote dotnet-monitor.
if [[ "${target_mode}" == "local" ]]; then
  echo "Next (optional runtime diagnostics): ${harness_core_dir}/capture/capture-runtime.sh ${artifact_dir}"
elif [[ "${remote_diagnostics:-0}" == "1" ]]; then
  echo "Next (optional REMOTE runtime diagnostics, separate perturbing run): ${harness_core_dir}/capture/capture-runtime.sh ${artifact_dir} <trace|gcdump|stacks> <seconds>"
fi
echo "Then analyze: ${harness_root}/ai/scripts/analyze-with-claude.sh ${artifact_dir}"
