#!/usr/bin/env bash
# dotnet runtime adapter -- capture in-process diagnostics via the dotnet-monitor
# sidecar. Invoked by harness/core/capture-runtime.sh, which has already
# recreated the app in diagnose mode and exported the workload env
# (PERF_METHOD/PATH/BODY/BASE_URL, PERFLAB_CONNECTIONS, PERFLAB_DURATION_SECONDS,
# PERFLAB_LOAD_GENERATOR, PERF_SCENARIO).
#
# Contract:  capture.sh <artifact-dir> <requested-kind> <duration-seconds> <target-service>
# Kinds:     trace | gcdump | stacks | dump  (stacks falls back to trace by default)
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"

artifact_dir="${1:?capture.sh <artifact-dir> <kind> <duration> <target-service>}"
requested_kind="${2:?diagnostic kind required}"
duration_seconds="${3:-30}"
target="${4:?target service required}"

assembly_name="$(diag_target "${target}" || true)"
if [[ -z "${assembly_name}" ]]; then
  echo "No PERFLAB_DIAG_TARGETS mapping for app service '${target}'." >&2
  exit 1
fi

# dotnet-monitor /stacks is unreliable in this Docker Desktop sidecar topology,
# so a managed-stacks request captures a CPU trace fallback unless explicitly
# re-enabled. The requested vs effective kind is recorded in capture.json.
kind="${requested_kind}"
fallback_reason=""
if [[ "${kind}" == "stacks" && "${PERFLAB_ENABLE_DOTNET_MONITOR_STACKS:-false}" != "true" ]]; then
  kind="trace"
  fallback_reason="dotnet-monitor /stacks is disabled by default because its in-process profiler channel is unreliable in this Docker Desktop sidecar topology"
  echo "Requested stacks for ${target}; capturing a CPU trace fallback instead."
  echo "Set PERFLAB_ENABLE_DOTNET_MONITOR_STACKS=true to explicitly retry /stacks."
fi

mkdir -p "${artifact_dir}/runtime/${target}"
capture_json="${artifact_dir}/runtime/capture.json"
fb_field=""
[[ -n "${fallback_reason}" ]] && fb_field=",\"fallbackReason\":\"$(json_escape "${fallback_reason}")\""
printf '{"scenarioId":"%s","target":"%s","loadGenerator":"%s","requestedDiagnostic":"%s","effectiveDiagnostic":"%s","durationSeconds":%s,"startedAt":"%s","status":"running"%s}\n' \
  "$(json_escape "${PERF_SCENARIO:-}")" "$(json_escape "${target}")" "$(json_escape "${load_generator}")" \
  "$(json_escape "${requested_kind}")" "$(json_escape "${kind}")" "${duration_seconds}" \
  "$(json_escape "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" "${fb_field}" > "${capture_json}"

processes_file="${artifact_dir}/runtime/processes-diagnostic.json"
curl -fsS "${diagnostics_url}/processes" > "${processes_file}"
runtime_uid="$(jqd -r --arg a "${assembly_name}" \
  '.[] | select(((.managedEntryPointAssemblyName // "") | contains($a)) or ((.name // "") | contains($a))) | .uid' \
  < "${processes_file}" | head -1)"
if [[ -z "${runtime_uid}" || "${runtime_uid}" == "null" ]]; then
  echo "Could not find ${assembly_name} in dotnet-monitor /processes." >&2
  exit 1
fi

run_load() { loadgen_measure "${artifact_dir}" diagnostic; }
out="${artifact_dir}/runtime/${target}"

case "${kind}" in
  trace)
    run_load & load_pid=$!
    curl -fsS --get \
      --data-urlencode "uid=${runtime_uid}" \
      --data-urlencode "durationSeconds=${duration_seconds}" \
      --data-urlencode "profile=cpu" \
      "${diagnostics_url}/trace" > "${out}/cpu.nettrace"
    wait "${load_pid}"
    ;;
  gcdump)
    curl -fsS --get --data-urlencode "uid=${runtime_uid}" "${diagnostics_url}/gcdump" > "${out}/before.gcdump"
    run_load
    curl -fsS --get --data-urlencode "uid=${runtime_uid}" "${diagnostics_url}/gcdump" > "${out}/after.gcdump"
    ;;
  stacks)
    run_load & load_pid=$!
    sleep 5
    curl -fsS --get --data-urlencode "uid=${runtime_uid}" "${diagnostics_url}/stacks" > "${out}/stacks.json"
    wait "${load_pid}"
    ;;
  dump)
    run_load & load_pid=$!
    sleep 5
    curl -fsS --get --data-urlencode "uid=${runtime_uid}" --data-urlencode "type=Heap" "${diagnostics_url}/dump" > "${out}/process.dmp"
    wait "${load_pid}"
    ;;
  *)
    echo "Unknown diagnostic '${kind}'. Use trace, gcdump, stacks, or dump." >&2
    exit 1
    ;;
esac

# Finalize capture.json (append top-level fields to our own JSON, no jq).
content="$(cat "${capture_json}")"; content="${content%\}}"
printf '%s,"completedAt":"%s","status":"captured"}\n' \
  "${content}" "$(json_escape "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" > "${capture_json}"
echo "Captured ${kind} for ${target}."
