#!/usr/bin/env bash
# dotnet runtime adapter -- capture in-process diagnostics via the dotnet-monitor
# sidecar. Invoked by harness/core/capture/capture-runtime.sh, which has already
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

# The capture runs a background load while curl pulls the artifact. If curl fails,
# `set -e` aborts before the `wait`, so a cleanup trap kills the background load on
# ANY exit (else it keeps hammering the app after the run). And every binary is
# staged through a .tmp so a failed fetch cannot leave a partial artifact that
# looks like a real capture.
load_pid=""
cleanup_load() {
  if [[ -n "${load_pid}" ]]; then
    kill "${load_pid}" 2>/dev/null || true
    wait "${load_pid}" 2>/dev/null || true
  fi
}
trap cleanup_load EXIT INT TERM

pull() {  # pull <dest-file> <curl-arg>...
  local dest="$1"; shift
  if curl -fsS "$@" > "${dest}.tmp"; then
    mv "${dest}.tmp" "${dest}"
  else
    rm -f "${dest}.tmp"
    echo "Diagnostic fetch failed for ${target} (${dest##*/}); the capture is incomplete." >&2
    exit 1   # the EXIT trap stops the background load; capture.json stays "running"
  fi
}

case "${kind}" in
  trace)
    run_load & load_pid=$!
    pull "${out}/cpu.nettrace" --get --data-urlencode "uid=${runtime_uid}" \
      --data-urlencode "durationSeconds=${duration_seconds}" --data-urlencode "profile=cpu" \
      "${diagnostics_url}/trace"
    wait "${load_pid}"; load_pid=""
    ;;
  gcdump)
    pull "${out}/before.gcdump" --get --data-urlencode "uid=${runtime_uid}" "${diagnostics_url}/gcdump"
    run_load
    pull "${out}/after.gcdump" --get --data-urlencode "uid=${runtime_uid}" "${diagnostics_url}/gcdump"
    ;;
  stacks)
    run_load & load_pid=$!
    sleep 5
    pull "${out}/stacks.json" --get --data-urlencode "uid=${runtime_uid}" "${diagnostics_url}/stacks"
    wait "${load_pid}"; load_pid=""
    ;;
  dump)
    run_load & load_pid=$!
    sleep 5
    pull "${out}/process.dmp" --get --data-urlencode "uid=${runtime_uid}" --data-urlencode "type=Heap" "${diagnostics_url}/dump"
    wait "${load_pid}"; load_pid=""
    ;;
  *)
    echo "Unknown diagnostic '${kind}'. Use trace, gcdump, stacks, or dump." >&2
    exit 1
    ;;
esac

# Finalize capture.json: replace the transient "running" status with a terminal
# "captured" and append completedAt (append-only edit, no jq). The initial write
# emits ...,"status":"running"[,"fallbackReason":...]; strip that status token
# first so the finalized object carries exactly one status key (a duplicate key
# is ambiguous JSON -- last-wins parsers say captured, strict/first-wins say
# running, which would falsely read as "capture never completed").
content="$(cat "${capture_json}")"; content="${content%\}}"
running_status=',"status":"running"'; content="${content/${running_status}/}"
printf '%s,"completedAt":"%s","status":"captured"}\n' \
  "${content}" "$(json_escape "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" > "${capture_json}"
echo "Captured ${kind} for ${target}."
