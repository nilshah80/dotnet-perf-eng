#!/usr/bin/env bash
# Capture in-process runtime diagnostics in a SEPARATE diagnose-mode run (kept
# apart from measurement because profiling perturbs the process). Runtime-
# specific capture is delegated to the runtime adapter's capture.sh.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

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

IFS=$'\t' read -r scenario_id telemetry_run_id manifest_generator manifest_target manifest_base_url manifest_ready_url manifest_method manifest_path manifest_body manifest_body_recorded manifest_dataset manifest_conns < <(
  jqd -r '[.scenarioId,(.telemetryRunId//.runId),(.workload.loadGenerator//"wrk"),(.target//"local"),(.workload.baseUrl//""),(.workload.readyUrl//""),(.workload.method//""),(.workload.path//""),(.workload.body//""),(if (.workload|has("body")) then "true" else "false" end),(.workload.datasetIdentity//""),(.workload.connections//"")] | @tsv' < "${manifest}")
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
  IFS=$'\t' read -r source_compat_generator source_compat_fingerprint source_compat_content source_compat_config < <(
    jqd -r '[.compatibility.generator//"",.compatibility.generatorFingerprint//"",.compatibility.workloadContentHash//"",.compatibility.configurationHash//""] | @tsv' < "${facts_file}")
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
else
  echo "Recreating app in diagnose mode for ${scenario_id}..."
  # shellcheck disable=SC2086
  compose up -d --force-recreate ${app_services}
  wait_for_api
fi

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
    IFS=$'\t' read -r diagnostic_generator diagnostic_fingerprint diagnostic_content diagnostic_base diagnostic_connections diagnostic_scenario diagnostic_method diagnostic_path < <(
      jqd -r '[.generator//"",.generatorFingerprint//"",.workloadContentHash//"",(.baseUrl//""|sub("/+$";"")),(.connections//""|tostring),.scenario//"",.method//"",.path//""] | @tsv' < "${diagnostic_compat}")
    IFS=$'\t' read -r source_generator source_fingerprint source_content source_base source_connections source_scenario source_method source_path < <(
      jqd -r '[.compatibility.generator//"",.compatibility.generatorFingerprint//"",.compatibility.workloadContentHash//"",(.compatibility.baseUrl//""|sub("/+$";"")),(.compatibility.connections//""|tostring),.compatibility.scenario//"",.compatibility.method//"",.compatibility.path//""] | @tsv' < "${artifact_dir}/facts.json")
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
