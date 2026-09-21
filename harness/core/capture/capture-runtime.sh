#!/usr/bin/env bash
# Capture in-process runtime diagnostics in a SEPARATE diagnose-mode run (kept
# apart from measurement because profiling perturbs the process). Runtime-
# specific capture is delegated to the runtime adapter's capture.sh.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/performance.sh"

artifact_dir="${1:?Usage: capture-runtime.sh <artifact-directory> [trace|gcdump|stacks|dump] [duration-seconds] | <artifact-directory> --preset <cpu|memory|cpu-memory|hang|dump> [duration-seconds] [--include-dump]}"
manifest="${artifact_dir}/manifest.json"
[[ -f "${manifest}" ]] || { echo "Manifest not found: ${manifest}" >&2; exit 1; }
if [[ -e "${artifact_dir}/runtime/capture.json" || -e "${artifact_dir}/runtime/campaign.json" ]]; then
  echo "Runtime capture already exists in ${artifact_dir}. A second diagnostic would overwrite its provenance and generator outputs; copy a measurement-only package to a new diagnostic directory and capture there." >&2
  exit 1
fi

capture_mode="kind"
requested_kind=""
requested_preset=""
include_dump="0"
if [[ "${2:-}" == "--preset" ]]; then
  capture_mode="preset"
  requested_preset="${3:-}"
  duration_seconds="30"
  case "${4:-}" in
    "") ;;
    --include-dump) include_dump="1" ;;
    *) duration_seconds="${4}" ;;
  esac
  if [[ -n "${5:-}" ]]; then
    if [[ "${4:-}" == "--include-dump" || "${5}" != "--include-dump" ]]; then
      echo "Preset usage: capture-runtime.sh <artifact-directory> --preset <name> [duration-seconds] [--include-dump]" >&2; exit 1
    fi
    include_dump="1"
  fi
  if (( $# > 5 )); then
    echo "Preset usage: capture-runtime.sh <artifact-directory> --preset <name> [duration-seconds] [--include-dump]" >&2; exit 1
  fi
  case "${requested_preset}" in
    cpu|memory|cpu-memory|hang|dump) ;;
    all) echo "There is intentionally no 'all' diagnostic preset. Use cpu-memory, or isolated copy-per-kind captures." >&2; exit 1 ;;
    *) echo "Unknown preset '${requested_preset}'. Use cpu, memory, cpu-memory, hang, or dump." >&2; exit 1 ;;
  esac
  if [[ "${include_dump}" == "1" && "${requested_preset}" != "hang" ]]; then
    echo "--include-dump is valid only with --preset hang." >&2; exit 1
  fi
else
  (( $# <= 3 )) || { echo "Kind usage: capture-runtime.sh <artifact-directory> [kind] [duration-seconds]" >&2; exit 1; }
  requested_kind="${2:-}"
  duration_seconds="${3:-30}"
fi
case "${duration_seconds}" in
  ''|*[!0-9]*) echo "Duration must be a positive integer number of seconds." >&2; exit 1 ;;
esac
(( duration_seconds > 0 )) || { echo "Duration must be positive." >&2; exit 1; }

dump_requested="0"
[[ "${capture_mode}" == "kind" && "${requested_kind}" == "dump" ]] && dump_requested="1"
[[ "${capture_mode}" == "preset" && "${requested_preset}" == "dump" ]] && dump_requested="1"
[[ "${capture_mode}" == "preset" && "${requested_preset}" == "hang" && "${include_dump}" == "1" ]] && dump_requested="1"
if [[ "${dump_requested}" == "1" && "${PERFLAB_DUMP_ACK:-}" != "i-understand-sensitive-dump" ]]; then
  echo "Process dumps may contain secrets or personal data. Set PERFLAB_DUMP_ACK=i-understand-sensitive-dump to acknowledge this capture." >&2
  exit 1
fi
if [[ "${PERFLAB_COLLECTION_RULES:-0}" == "1" ]]; then
  if [[ "${PERFLAB_DUMP_ACK:-}" != "i-understand-sensitive-dump" ]]; then
    echo "Collection rules arm crash dumps. Set PERFLAB_DUMP_ACK=i-understand-sensitive-dump before PERFLAB_COLLECTION_RULES=1." >&2
    exit 1
  fi
  if [[ "${target_mode}" == "remote" || "${PERFLAB_TARGET_KIND:-managed-compose}" != "managed-compose" ]]; then
    echo "Collection rules require an owned target; refusing to pre-arm crash dumps on a remote process." >&2
    exit 1
  fi
  # This is the same configuration file that the gated monitor image loads
  # with --configuration-file-path. Do not substitute a descriptive policy for
  # the live rule: the artifact must show exactly the trigger, action, egress,
  # and ActionCount limit that governed the capture.
  collection_rules_file="${repo_root}/harness/adapters/runtime/dotnet/monitor/collection-rules.json"
  [[ -f "${collection_rules_file}" ]] || { echo "Missing dotnet-monitor CollectionRules configuration: ${collection_rules_file}" >&2; exit 1; }
  mkdir -p "${artifact_dir}/runtime"
  cp "${collection_rules_file}" "${artifact_dir}/runtime/collection-rules.json"
  # Do not combine a process-level createdump hook with the monitor rule. The
  # hook writes to the shared volume before any bound can be applied; the rule
  # egress is instead mounted as a dedicated 512 MiB tmpfs in the monitor.
  unset PERFLAB_DBG_ENABLE_MINIDUMP
  echo "dotnet-monitor CollectionRules armed (${collection_rules_file}); Triage dumps remain local, tmpfs-bounded, and non-exportable."
fi

# The disk check and budget applied only to CAMPAIGNS. A direct `dump` writes a
# full-heap process dump -- the largest artifact this harness produces -- with no
# budget and no free-space check at all, so the one capture most able to fill a
# disk was the one least protected.
if [[ "${capture_mode}" != "preset" ]]; then
  direct_budget="${PERFLAB_DIAGNOSTIC_ARTIFACT_BUDGET_BYTES:-1073741824}"
  case "${direct_budget}" in ''|*[!0-9]*) echo "PERFLAB_DIAGNOSTIC_ARTIFACT_BUDGET_BYTES must be an integer." >&2; exit 1 ;; esac
  direct_available_kib="$(df -Pk "${artifact_dir}" | awk 'NR==2 {print $4}')"
  (( direct_available_kib * 1024 >= direct_budget )) || {
    echo "Insufficient free disk for the ${direct_budget}-byte diagnostic artifact budget." >&2
    exit 1
  }
  export PERFLAB_DIAGNOSTIC_ARTIFACT_BUDGET_BYTES="${direct_budget}"
fi

if [[ "${capture_mode}" == "preset" ]]; then
  campaign_budget="${PERFLAB_DIAGNOSTIC_ARTIFACT_BUDGET_BYTES:-1073741824}"
  case "${campaign_budget}" in ''|*[!0-9]*) echo "PERFLAB_DIAGNOSTIC_ARTIFACT_BUDGET_BYTES must be an integer." >&2; exit 1 ;; esac
  (( campaign_budget >= 67108864 )) || { echo "Diagnostic campaigns require at least a 67108864-byte artifact budget." >&2; exit 1; }
  available_kib="$(df -Pk "${artifact_dir}" | awk 'NR==2 {print $4}')"
  (( available_kib * 1024 >= campaign_budget )) || { echo "Insufficient free disk for the ${campaign_budget}-byte diagnostic campaign budget." >&2; exit 1; }
  export PERFLAB_DIAGNOSTIC_PRESET="${requested_preset}"
  export PERFLAB_DIAGNOSTIC_INCLUDE_DUMP="${include_dump}"
  export PERFLAB_DIAGNOSTIC_RECOVERY_SECONDS="${PERFLAB_DIAGNOSTIC_RECOVERY_SECONDS:-2}"
  case "${PERFLAB_DIAGNOSTIC_RECOVERY_SECONDS}" in ''|*[!0-9]*) echo "PERFLAB_DIAGNOSTIC_RECOVERY_SECONDS must be an integer 0-60." >&2; exit 1 ;; esac
  (( PERFLAB_DIAGNOSTIC_RECOVERY_SECONDS <= 60 )) || { echo "PERFLAB_DIAGNOSTIC_RECOVERY_SECONDS must be 0-60." >&2; exit 1; }
  export PERFLAB_DIAGNOSTIC_ARTIFACT_BUDGET_BYTES="${campaign_budget}"
fi

# Read one field per line, NOT `IFS=$'\t' read`. Bash treats tab as IFS
# WHITESPACE, so consecutive tabs collapse into a single delimiter: a workload
# with an empty body -- every GET scenario -- shifted every later field left by
# one, and the replay envelope was built from `body=true`, `dataset=64`,
# `conns=''`. The diagnostic then replayed a different workload than the one
# measured, which is precisely what the recorded envelope exists to prevent.
manifest_fields=()
while IFS= read -r manifest_field; do
  manifest_fields+=("${manifest_field}")
done < <(jqd -r '[.scenarioId,(.telemetryRunId//.runId),(.workload.loadGenerator//"wrk"),(.target//"local"),(.workload.baseUrl//""),(.workload.readyUrl//""),(.workload.method//""),(.workload.path//""),(.workload.body//""),(if (.workload|has("body")) then "true" else "false" end),(.workload.datasetIdentity//""),(.workload.connections//"")] | .[] | tostring' < "${manifest}")
if [[ "${#manifest_fields[@]}" -ne 12 ]]; then
  echo "Manifest workload envelope has ${#manifest_fields[@]} fields, expected 12; refusing to replay a workload this run cannot reconstruct." >&2
  exit 1
fi
scenario_id="${manifest_fields[0]}"
telemetry_run_id="${manifest_fields[1]}"
# Keep the source measurement's profiler state separate from the diagnose
# process state. A stacks request following a profiled measurement uses the
# trace fallback even when this owned child could be recreated differently:
# dotnet-monitor's stacks attach is not reliable in that combination.
source_continuous_profiling="$(jqd -r '(.continuousProfiling // false) | if . then "1" else "0" end' < "${manifest}")"
if [[ "${continuous_profiling:-0}" == "1" ]]; then
  measured_policy="$(jqd -r '.profilingPolicy // empty' < "${manifest}")"
  measured_types="$(jqd -r '.profilingTypes // empty' < "${manifest}")"
  if [[ -n "${measured_types}" ]]; then
    export PERFLAB_PROFILING_POLICY="${measured_policy:-cpu}"
    export PERFLAB_PROFILING_TYPES="${measured_types}"
    export PERFLAB_PROFILING_POLICY_SOURCE="measurement"
  else
    resolve_profiling_policy "${scenario_id}" || exit 1
  fi
fi
manifest_generator="${manifest_fields[2]}"
manifest_target="${manifest_fields[3]}"
manifest_base_url="${manifest_fields[4]}"
manifest_ready_url="${manifest_fields[5]}"
manifest_method="${manifest_fields[6]}"
manifest_path="${manifest_fields[7]}"
manifest_body="${manifest_fields[8]}"
manifest_body_recorded="${manifest_fields[9]}"
manifest_dataset="${manifest_fields[10]}"
manifest_conns="${manifest_fields[11]}"
# Bind the readiness check to the endpoint that was MEASURED, so a re-run does not
# probe the current lab default (e.g. localhost) while loading the remote target.
[[ -n "${manifest_ready_url}" ]] && ready_url="${manifest_ready_url}"

# The recorded target is authoritative. Refuse a mismatch BEFORE any load, lifecycle
# or capture: opening a REMOTE artifact with a LOCAL lab selected would otherwise take
# the local path and 'compose up --force-recreate' the wrong (local) app.
if [[ "${manifest_target:-local}" != "${target_mode}" ]]; then
  echo "Target mismatch: this package was captured as target='${manifest_target}', but the selected lab resolves target='${target_mode}'. Select the matching lab (PERFLAB_LAB=...) / PERFLAB_TARGET so diagnostics act on the intended app." >&2
  exit 1
fi

# Default the diagnostic load to the measurement's generator so the two runs
# stay comparable; an explicit env override wins.
load_generator="${PERFLAB_LOAD_GENERATOR:-${manifest_generator}}"
if [[ "${load_generator}" != "wrk" && "${load_generator}" != "k6" && "${load_generator}" != "jmeter" ]]; then
  echo "PERFLAB_LOAD_GENERATOR must be 'wrk', 'k6', or 'jmeter'; received '${load_generator}'." >&2
  exit 1
fi
if [[ "${capture_mode}" == "preset" && "${load_generator}" != "${manifest_generator}" ]]; then
  echo "Diagnostic campaigns must replay the measured generator '${manifest_generator}'; override '${load_generator}' was refused." >&2
  exit 1
fi
if [[ "${capture_mode}" == "preset" && "${requested_preset}" != "dump" ]]; then
  if [[ "${load_generator}" != "k6" && "${load_generator}" != "jmeter" ]]; then
    echo "Load-bearing diagnostic campaigns require a measured k6 or JMeter workload; '${load_generator}' cannot provide replay provenance." >&2
    exit 1
  fi
  if [[ "${manifest_body_recorded}" != "true" || -z "${manifest_dataset}" ]]; then
    echo "This measurement predates recorded body/dataset replay identity. Create a fresh measurement before starting a diagnostic campaign." >&2
    exit 1
  fi
  if [[ "${manifest_method}" == "MIX" ]]; then
    echo "Diagnostic campaigns do not replay an unrecorded PERF_MIX definition. Use a catalog scenario or isolated diagnostics." >&2
    exit 1
  fi
  facts_file="${artifact_dir}/facts.json"
  [[ -s "${facts_file}" ]] || { echo "A diagnostic campaign requires the source measurement facts.json." >&2; exit 1; }
  read_fields 4 < <(
    jqd -r '[.compatibility.generator//"",.compatibility.generatorFingerprint//"",.compatibility.workloadContentHash//"",.compatibility.configurationHash//""] | .[] | tostring' < "${facts_file}") || exit 1
  source_compat_generator="${TSV_FIELDS[0]}"; source_compat_fingerprint="${TSV_FIELDS[1]}"
  source_compat_content="${TSV_FIELDS[2]}"; source_compat_config="${TSV_FIELDS[3]}"
  if [[ "${source_compat_generator}" != "${manifest_generator}" || -z "${source_compat_fingerprint}" || ! "${source_compat_content}" =~ ^[a-f0-9]{64}$ || ! "${source_compat_config}" =~ ^[a-f0-9]{64}$ ]]; then
    echo "The source measurement lacks a valid ${manifest_generator} generator/workload/configuration compatibility envelope. Create a fresh measurement." >&2
    exit 1
  fi
fi
if [[ "${capture_mode}" != "preset" || "${requested_preset}" != "dump" ]]; then
  require_loadgen
fi
export PERFLAB_LOAD_GENERATOR="${load_generator}"

if [[ "${capture_mode}" == "kind" && -z "${requested_kind}" ]]; then
  requested_kind="$(scenario_value "${scenario_id}" diagnostic)"
fi
if [[ "${capture_mode}" == "kind" ]]; then
  case "${requested_kind}" in trace|gcdump|stacks|dump) ;; *) echo "Unknown diagnostic '${requested_kind}'. Use trace, gcdump, stacks, or dump." >&2; exit 1 ;; esac
fi
if [[ "${requested_kind}" == "dump" && "${PERFLAB_DUMP_ACK:-}" != "i-understand-sensitive-dump" ]]; then
  echo "Process dumps may contain secrets or personal data. Set PERFLAB_DUMP_ACK=i-understand-sensitive-dump to acknowledge this capture." >&2
  exit 1
fi
target="$(scenario_value "${scenario_id}" target)"

stacks_requested="0"
[[ "${requested_kind}" == "stacks" || "${requested_preset}" == "hang" ]] && stacks_requested="1"
gcdump_requested="0"
[[ "${requested_kind}" == "gcdump" ]] && gcdump_requested="1"
[[ "${requested_preset}" == "memory" || "${requested_preset}" == "cpu-memory" ]] && gcdump_requested="1"

export PERF_SCENARIO="${scenario_id}" PERF_RUN_ID="${telemetry_run_id}" PERF_RUN_MODE="diagnose"
# Bind the diagnostic load to what was MEASURED (recorded in the manifest), not
# whatever the current lab.config/catalog now resolves. Otherwise a re-diagnosed
# remote package would profile the remote process while hammering the lab default
# (e.g. localhost), or replay a since-edited catalog's different request. New
# measurements record the body; legacy isolated captures retain the catalog fallback.
export PERF_METHOD="${manifest_method:-$(scenario_value "${scenario_id}" method)}"
export PERF_PATH="${manifest_path:-$(scenario_value "${scenario_id}" path)}"
if [[ "${manifest_body_recorded}" == "true" ]]; then
  export PERF_BODY="${manifest_body}"
else
  export PERF_BODY="$(scenario_value "${scenario_id}" body)"
fi
export PERF_BASE_URL="${manifest_base_url:-${base_url}}"
export PERFLAB_CONNECTIONS="${manifest_conns:-$(scenario_value "${scenario_id}" connections)}"
export PERFLAB_DURATION_SECONDS="${duration_seconds}" PERFLAB_PROFILE="steady"
if [[ "${manifest_dataset}" == seedScale=* ]]; then
  recorded_seed_scale="${manifest_dataset#seedScale=}"
  if [[ "${recorded_seed_scale}" == "default" ]]; then
    unset SEED_SCALE
  else
    export SEED_SCALE="${recorded_seed_scale}"
  fi
fi

# D-P0-3. An inherited PERFLAB_ENABLE_DOTNET_MONITOR_STACKS=true from the
# operator environment must not arm ICorProfiler on a remote or attach-only
# target. The flag is set only after a successful owned compose recreate.
unset PERFLAB_ENABLE_DOTNET_MONITOR_STACKS
unset PERFLAB_STACKS_FORCE_TRACE
export target_mode
export PERFLAB_TARGET_KIND="${PERFLAB_TARGET_KIND:-managed-compose}"

if [[ "${source_continuous_profiling}" == "1" && "${gcdump_requested}" == "1" && \
      ( "${target_mode}" == "remote" || "${PERFLAB_TARGET_KIND}" != "managed-compose" ) ]]; then
  echo "Refusing gcdump after continuous profiling: this target is not owned, so it cannot be recreated with PERFLAB_CONTINUOUS_PROFILING=0 to preserve managed type metadata." >&2
  exit 1
fi

if [[ "${target_mode}" == "remote" ]]; then
  # Remote diagnostics: the app is NOT owned, so it is NOT recreated. Gated behind
  # opt-in (PERFLAB_REMOTE_DIAGNOSTICS=1) AND an explicit ack, because attaching a
  # profiler / pulling a gcdump or dump PERTURBS the live target (a gcdump pauses
  # the GC; a dump freezes the process; a trace adds overhead) and can expose
  # secrets/PII from process memory. The deployed app must already expose a
  # reachable dotnet-monitor at PERFLAB_DIAGNOSTICS_URL, with PERFLAB_DIAG_TARGETS
  # mapping the scenario's target service to its process/assembly name.
  if [[ "${remote_diagnostics}" != "1" ]]; then
    echo "Remote runtime diagnostics are disabled. Set PERFLAB_REMOTE_DIAGNOSTICS=1 to enable, and provide a reachable PERFLAB_DIAGNOSTICS_URL + PERFLAB_DIAG_TARGETS for the deployed app." >&2
    exit 1
  fi
  if [[ "${PERFLAB_REMOTE_DIAG_ACK:-}" != "${remote_diag_ack_phrase}" ]]; then
    echo "Remote diagnostics need an explicit acknowledgement: set PERFLAB_REMOTE_DIAG_ACK=${remote_diag_ack_phrase}" >&2
    echo "  WHY: diagnostics PERTURB the live target (gcdump pauses the GC; dump freezes the process; a trace adds overhead) and can expose secrets/PII from process memory. Prefer staging, run this SEPARATELY from any measurement run, and confirm you are authorized to attach a diagnostic tool to that process." >&2
    exit 1
  fi
  echo "Remote diagnostics against ${diagnostics_url} for ${scenario_id} (target NOT recreated; perturbation acknowledged)."
  # Load-bearing diagnostics replay the scenario against the live target. A
  # dump-only preset does not send traffic and therefore needs no write ack.
  if [[ "${capture_mode}" != "preset" || "${requested_preset}" != "dump" ]]; then
    case "${PERF_METHOD}" in
      GET|HEAD) : ;;
      *)
        if [[ "${PERFLAB_REMOTE_WRITE_ACK:-}" != "${remote_write_ack_phrase}" ]]; then
          echo "Refusing remote diagnostics for a ${PERF_METHOD} scenario: replaying it drives REAL ${PERF_METHOD} traffic and MUTATES data on ${PERF_BASE_URL}. The perturbation ack does not cover data mutation -- set PERFLAB_REMOTE_WRITE_ACK=${remote_write_ack_phrase} to confirm, or use a read scenario / disposable dataset." >&2
          exit 1
        fi
        echo "WARNING: ${PERF_METHOD} scenario ${scenario_id} -- diagnostic load WILL MUTATE data on ${PERF_BASE_URL} (PERFLAB_REMOTE_WRITE_ACK accepted)." >&2 ;;
    esac
  fi
  # Fail CLOSED on an unreachable target (as run-scenario.sh does); override with
  # PERFLAB_REMOTE_ALLOW_UNHEALTHY=1 to diagnose a deliberately degraded target.
  if ! curl -fsS --max-time 10 "${ready_url}" >/dev/null 2>&1; then
    if [[ "${PERFLAB_REMOTE_ALLOW_UNHEALTHY:-0}" == "1" ]]; then
      echo "WARNING: remote readiness check failed at ${ready_url}; PERFLAB_REMOTE_ALLOW_UNHEALTHY=1 set, continuing." >&2
    else
      echo "ERROR: remote readiness check failed at ${ready_url}. Refusing to drive diagnostic load against an unhealthy target; set PERFLAB_REMOTE_ALLOW_UNHEALTHY=1 to override." >&2
      exit 1
    fi
  fi
elif [[ "${PERFLAB_TARGET_KIND:-managed-compose}" != "managed-compose" ]]; then
  # C-5. Attach-only: the target was not created by this run, so recreating it
  # would restart somebody else's process. The capture still happens -- it just
  # observes the process as found, and records that it did, because a diagnose
  # run that did NOT start from a clean process is a different measurement and
  # the reader has to know which one they have.
  echo "Attaching to an existing ${PERFLAB_TARGET_KIND} target for ${scenario_id} (not recreated; leaks and pools from prior traffic are still present)."
  wait_for_api
else
  echo "Recreating app in diagnose mode for ${scenario_id}..."
  require_target_ownership "recreate the application for a diagnostic capture" || exit 1
  stacks_trace_fallback=0
  # dotnet-monitor's /stacks path is unreliable after a continuously profiled
  # source measurement. Keep the explicit CPU-trace fallback rather than
  # claiming the call-stack channel is usable merely because this child is
  # owned. An unprofiled source still uses the working owned /stacks path.
  if [[ "${stacks_requested}" == "1" && "${source_continuous_profiling}" == "1" ]]; then
    export PERFLAB_STACKS_FORCE_TRACE=1
    stacks_trace_fallback=1
    echo "Diagnose-mode /stacks after continuous profiling: retaining the CPU-trace fallback (dotnet-monitor stacks attach is unreliable)."
  elif [[ "${stacks_requested}" == "1" ]]; then
    export PERFLAB_CONTINUOUS_PROFILING=0
    unset PERFLAB_PROFILING_POLICY PERFLAB_PROFILING_POLICY_SOURCE PERFLAB_PROFILING_TYPES PERFLAB_PROFILING_KEEP_TIERING
    continuous_profiling=0
    echo "Diagnose-mode /stacks: recreating with PERFLAB_CONTINUOUS_PROFILING=0 so ICorProfiler is free."
  fi
  # A gcdump taken while the Pyroscope profiler is loaded can keep byte counts
  # but lose every managed type name. Recreate owned targets with profiling off
  # before any direct or campaign heap capture.
  if [[ "${gcdump_requested}" == "1" ]]; then
    export PERFLAB_CONTINUOUS_PROFILING=0
    unset PERFLAB_PROFILING_POLICY PERFLAB_PROFILING_POLICY_SOURCE PERFLAB_PROFILING_TYPES PERFLAB_PROFILING_KEEP_TIERING
    continuous_profiling=0
    echo "Diagnose-mode gcdump: recreating with PERFLAB_CONTINUOUS_PROFILING=0 to preserve managed type metadata."
  fi
  # shellcheck disable=SC2086
  compose up -d --force-recreate ${app_services}
  wait_for_api
  if [[ "${stacks_requested}" == "1" && "${stacks_trace_fallback}" == "0" ]]; then
    export PERFLAB_ENABLE_DOTNET_MONITOR_STACKS=true
  fi
fi

# A diagnostic perturbs the process, so only one may run against a given target
# at a time. Keyed on the target identity rather than the run id: two different
# runs pointed at the same process must still collide.
acquire_diagnostic_lease "${PERFLAB_LAB:-lab}/${target}/${diagnostics_url}" || exit 1
trap 'release_diagnostic_lease' EXIT INT TERM

capture="${runtime_adapter_dir}/capture.sh"
if [[ ! -f "${capture}" ]]; then
  echo "Runtime adapter '${runtime}' has no capture.sh at ${capture}." >&2
  exit 1
fi
measurement_guard() {
  local guarded
  for guarded in "${artifact_dir}/facts.json" "${artifact_dir}/benchmark/observations.json" "${artifact_dir}/benchmark/compatibility.json"; do
    [[ -f "${guarded}" ]] || continue
    if command -v openssl >/dev/null 2>&1; then
      openssl dgst -sha256 "${guarded}"
    else
      shasum -a 256 "${guarded}"
    fi
  done
}
measurement_before="$(measurement_guard)"
capture_rc=0
if [[ "${capture_mode}" == "preset" ]]; then
  "${capture}" "${artifact_dir}" "preset:${requested_preset}" "${duration_seconds}" "${target}" || capture_rc=$?
else
  "${capture}" "${artifact_dir}" "${requested_kind}" "${duration_seconds}" "${target}" || capture_rc=$?
fi
measurement_after="$(measurement_guard)"
if [[ "${PERFLAB_COLLECTION_RULES:-0}" == "1" && "${target_mode}" != "remote" ]]; then
  crash_dir="${artifact_dir}/runtime/crash-dumps"
  collection_dump_dir="${crash_dir}/collection-rules"
  mkdir -p "${collection_dump_dir}"
  performance_crash_dump_collect_path_from dotnet-monitor /diag/collection-rule-dumps "${collection_dump_dir}" || {
    echo "Failed to copy or purge dotnet-monitor CollectionRules egress; refusing to leave an unenforced dump source." >&2
    exit 1
  }
  collection_dump_count="$(find "${collection_dump_dir}" -type f ! -name '.*' | wc -l | tr -d ' ')"
  if [[ "${collection_dump_count}" != "1" ]]; then
    echo "CollectionRules was armed but did not yield exactly one in-budget local Triage dump (found ${collection_dump_count})." >&2
    exit 1
  fi
  rule_identity="${artifact_dir}/runtime/target-identity.json"
  [[ -s "${rule_identity}" ]] || { echo "CollectionRules was armed but the diagnostic target identity was not recorded." >&2; exit 1; }
  rule_uid="$(jqd -r '.uid // empty' < "${rule_identity}")"
  [[ -n "${rule_uid}" ]] || { echo "CollectionRules was armed but target identity contains no monitor uid." >&2; exit 1; }
  rules_status_file="${artifact_dir}/runtime/collection-rules-status.json"
  if ! monitor_curl -fsS --get --data-urlencode "uid=${rule_uid}" "${diagnostics_url}/collectionrules" > "${rules_status_file}"; then
    echo "Could not verify the live dotnet-monitor CollectionRules state for uid ${rule_uid}." >&2
    exit 1
  fi
  rule_state="$(jqd -r '.PerflabCrashDump.state // empty' < "${rules_status_file}")"
  rule_reason="$(jqd -r '.PerflabCrashDump.stateReason // empty' < "${rules_status_file}")"
  case "${rule_state}" in
    Running|Executing|Throttled|Completed) ;;
    *) echo "dotnet-monitor did not report an active PerflabCrashDump CollectionRule (state='${rule_state:-empty}', reason='${rule_reason:-empty}')." >&2; exit 1 ;;
  esac
  jqd -nc --arg state "${rule_state}" --arg reason "${rule_reason}" --arg uid "${rule_uid}" \
    --arg egress "/diag/collection-rule-dumps" --argjson dumps "${collection_dump_count}" \
    '{version:"perflab-dotnet-monitor-collection-rules-v1",state:$state,stateReason:$reason,targetUid:$uid,egress:$egress,localDumps:$dumps,maxBytes:536870912,actionCountLimit:1,sensitiveDataPolicy:"ack-required-not-exportable"}' \
    > "${rules_status_file}"
  performance_crash_dump_enforce "${crash_dir}"
fi
if [[ "${measurement_before}" != "${measurement_after}" ]]; then
  echo "Runtime diagnostics changed measured facts or observations; refusing the mutated evidence package." >&2
  exit 1
fi
replay_verification_state="not-applicable"
replay_verification_reason="dump-only campaign did not execute a load generator"
if [[ "${capture_mode}" == "preset" && "${requested_preset}" != "dump" ]]; then
  replay_verification_state="failed"
  replay_verification_reason="diagnostic load did not publish a compatibility envelope"
  diagnostic_compat="${artifact_dir}/runtime/campaign-load/benchmark/compatibility.json"
  if [[ -s "${diagnostic_compat}" ]]; then
    read_fields 8 < <(
      jqd -r '[.generator//"",.generatorFingerprint//"",.workloadContentHash//"",(.baseUrl//""|sub("/+$";"")),(.connections//""|tostring),.scenario//"",.method//"",.path//""] | .[] | tostring' < "${diagnostic_compat}") || exit 1
    diagnostic_generator="${TSV_FIELDS[0]}"; diagnostic_fingerprint="${TSV_FIELDS[1]}"
    diagnostic_content="${TSV_FIELDS[2]}"; diagnostic_base="${TSV_FIELDS[3]}"
    diagnostic_connections="${TSV_FIELDS[4]}"; diagnostic_scenario="${TSV_FIELDS[5]}"
    diagnostic_method="${TSV_FIELDS[6]}"; diagnostic_path="${TSV_FIELDS[7]}"
    read_fields 8 < <(
      jqd -r '[.compatibility.generator//"",.compatibility.generatorFingerprint//"",.compatibility.workloadContentHash//"",(.compatibility.baseUrl//""|sub("/+$";"")),(.compatibility.connections//""|tostring),.compatibility.scenario//"",.compatibility.method//"",.compatibility.path//""] | .[] | tostring' < "${artifact_dir}/facts.json") || exit 1
    source_generator="${TSV_FIELDS[0]}"; source_fingerprint="${TSV_FIELDS[1]}"
    source_content="${TSV_FIELDS[2]}"; source_base="${TSV_FIELDS[3]}"
    source_connections="${TSV_FIELDS[4]}"; source_scenario="${TSV_FIELDS[5]}"
    source_method="${TSV_FIELDS[6]}"; source_path="${TSV_FIELDS[7]}"
    if [[ "${diagnostic_generator}" == "${source_generator}" && "${diagnostic_fingerprint}" == "${source_fingerprint}" && \
          "${diagnostic_content}" == "${source_content}" && "${diagnostic_base}" == "${source_base}" && \
          "${diagnostic_connections}" == "${source_connections}" && "${diagnostic_scenario}" == "${source_scenario}" && \
          "${diagnostic_method}" == "${source_method}" && "${diagnostic_path}" == "${source_path}" ]]; then
      replay_verification_state="captured"
      replay_verification_reason=""
    else
      replay_verification_reason="diagnostic generator, workload hash, endpoint, connections, or route differs from the source measurement"
    fi
  fi
  if [[ "${replay_verification_state}" != "captured" && "${capture_rc}" -eq 0 ]]; then
    capture_rc=2
  fi
fi
if [[ "${capture_mode}" == "preset" && -f "${artifact_dir}/runtime/campaign.json" ]]; then
  finalize_rc=0
  if [[ -f "${artifact_dir}/facts.json" ]]; then
    finalize_filter='.[0] as $c | .[1] as $m | .[2] as $f | ($c + {measurementEvidencePreserved:true,sourceMeasurement:{runId:($m.telemetryRunId//$m.runId),scenarioId:$m.scenarioId,workload:$m.workload,source:($m.source//{}),compatibility:($f.compatibility//{})},replayVerification:{captureState:$verify,reason:$reason}}) | if $verify=="failed" and .status=="captured" then .status="partial" else . end'
    jqd -s --arg verify "${replay_verification_state}" --arg reason "${replay_verification_reason}" "${finalize_filter}" < <(cat "${artifact_dir}/runtime/campaign.json" "${manifest}" "${artifact_dir}/facts.json") > "${artifact_dir}/runtime/campaign.json.tmp" || finalize_rc=$?
  else
    finalize_filter='.[0] as $c | .[1] as $m | ($c + {measurementEvidencePreserved:true,sourceMeasurement:{runId:($m.telemetryRunId//$m.runId),scenarioId:$m.scenarioId,workload:$m.workload,source:($m.source//{}),compatibility:{}},replayVerification:{captureState:$verify,reason:$reason}}) | if $verify=="failed" and .status=="captured" then .status="partial" else . end'
    jqd -s --arg verify "${replay_verification_state}" --arg reason "${replay_verification_reason}" "${finalize_filter}" < <(cat "${artifact_dir}/runtime/campaign.json" "${manifest}") > "${artifact_dir}/runtime/campaign.json.tmp" || finalize_rc=$?
  fi
  if (( finalize_rc == 0 )); then
    mv "${artifact_dir}/runtime/campaign.json.tmp" "${artifact_dir}/runtime/campaign.json"
  else
    rm -f "${artifact_dir}/runtime/campaign.json.tmp"
    echo "Could not finalize the runtime campaign measurement-preservation assertion." >&2
    exit 1
  fi
fi
(( capture_rc == 0 )) || exit "${capture_rc}"

if [[ "${target_mode}" == "remote" ]]; then
  echo "Raw capture saved under ${artifact_dir}/runtime/ -- normalize it OFFLINE (a local lab with the diagnostics tools container, or dotnet-trace convert / PerfView / speedscope). In-place normalization needs that local container."
else
  echo "Normalize it with: ${harness_core_dir}/capture/normalize-runtime.sh ${artifact_dir}"
fi
