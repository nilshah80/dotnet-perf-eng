#!/usr/bin/env bash
# Capture in-process runtime diagnostics in a SEPARATE diagnose-mode run (kept
# apart from measurement because profiling perturbs the process). Runtime-
# specific capture is delegated to the runtime adapter's capture.sh.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

artifact_dir="${1:?Usage: capture-runtime.sh <artifact-directory> [trace|gcdump|stacks|dump] [duration-seconds]}"
manifest="${artifact_dir}/manifest.json"
[[ -f "${manifest}" ]] || { echo "Manifest not found: ${manifest}" >&2; exit 1; }

IFS=$'\t' read -r scenario_id telemetry_run_id manifest_generator manifest_target manifest_base_url manifest_ready_url manifest_method manifest_path manifest_conns < <(
  jqd -r '[.scenarioId,(.telemetryRunId//.runId),(.workload.loadGenerator//"wrk"),(.target//"local"),(.workload.baseUrl//""),(.workload.readyUrl//""),(.workload.method//""),(.workload.path//""),(.workload.connections//"")] | @tsv' < "${manifest}")
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
# Bind the diagnostic load to what was MEASURED (recorded in the manifest), not
# whatever the current lab.config/catalog now resolves. Otherwise a re-diagnosed
# remote package would profile the remote process while hammering the lab default
# (e.g. localhost), or replay a since-edited catalog's different request. Body is not
# in the manifest, so it still comes from the catalog (empty for the GET scenarios).
export PERF_METHOD="${manifest_method:-$(scenario_value "${scenario_id}" method)}"
export PERF_PATH="${manifest_path:-$(scenario_value "${scenario_id}" path)}"
export PERF_BODY="$(scenario_value "${scenario_id}" body)"
export PERF_BASE_URL="${manifest_base_url:-${base_url}}"
export PERFLAB_CONNECTIONS="${manifest_conns:-$(scenario_value "${scenario_id}" connections)}"
export PERFLAB_DURATION_SECONDS="${duration_seconds}"

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
  # The diagnostic run also drives the scenario workload against the live target, so a
  # non-GET method mutates remote data. That is beyond the perturbation/PII ack, so it
  # needs its OWN acknowledgement -- a warning is not a guard.
  case "${PERF_METHOD}" in
    GET|HEAD) : ;;
    *)
      if [[ "${PERFLAB_REMOTE_WRITE_ACK:-}" != "${remote_write_ack_phrase}" ]]; then
        echo "Refusing remote diagnostics for a ${PERF_METHOD} scenario: replaying it drives REAL ${PERF_METHOD} traffic and MUTATES data on ${PERF_BASE_URL}. The perturbation ack does not cover data mutation -- set PERFLAB_REMOTE_WRITE_ACK=${remote_write_ack_phrase} to confirm, or use a read scenario / disposable dataset." >&2
        exit 1
      fi
      echo "WARNING: ${PERF_METHOD} scenario ${scenario_id} -- diagnostic load WILL MUTATE data on ${PERF_BASE_URL} (PERFLAB_REMOTE_WRITE_ACK accepted)." >&2 ;;
  esac
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
"${capture}" "${artifact_dir}" "${requested_kind}" "${duration_seconds}" "${target}"

if [[ "${target_mode}" == "remote" ]]; then
  echo "Raw capture saved under ${artifact_dir}/runtime/ -- normalize it OFFLINE (a local lab with the diagnostics tools container, or dotnet-trace convert / PerfView / speedscope). In-place normalization needs that local container."
else
  echo "Normalize it with: ${harness_core_dir}/capture/normalize-runtime.sh ${artifact_dir}"
fi
